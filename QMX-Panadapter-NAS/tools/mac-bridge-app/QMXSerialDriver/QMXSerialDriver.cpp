// QMXSerialDriver.cpp - virtual serial port for the QMX Bridge app.
//
// The serial family (kernel) owns two rings shared with this driver:
//   rx ring: this driver produces (rxPI), the kernel consumes (rxCI) -> what programs read
//   tx ring: the kernel produces (txPI), this driver consumes (txCI) -> what programs wrote
// The indices live in the SerialPortInterface block at the start of ifmd.
//
// Index arithmetic: Apple does not document whether the indices run free (used =
// PI - CI, position = PI & mask) or wrap at the ring size. Mode 0 (default) is free
// running; mode 1 wraps. Seeing any kernel-owned index >= ring size proves mode 0, and
// the driver switches to it by itself. The app can force a mode (kQMXMethodSetRingMode).

#include <os/log.h>
#include <DriverKit/DriverKit.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IOMemoryMap.h>
#include <DriverKit/OSData.h>
#include <SerialDriverKit/SerialDriverKit.h>
#include <SerialDriverKit/SerialPortInterface.h>

#include "QMXSerialDriver.h"
#include "QMXBridgeUserClient.h"
#include "../Shared/QMXBridgeShared.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "QMXSerialDriver: " fmt, ##__VA_ARGS__)

using driverkit::serial::SerialPortInterface;

// The one serial port instance, for the control service's user clients.
IOLock *          gQMXLock   = nullptr;
QMXSerialDriver * gQMXSerial = nullptr;

struct QMXSerialDriver_IVars {
    IOLock *                lock;
    SerialPortInterface *   spi;
    IOMemoryMap *           rxMap;
    IOMemoryMap *           txMap;
    uint8_t *               rxBase;     // ring start (offset applied)
    uint8_t *               txBase;
    uint32_t                rxSize;
    uint32_t                txSize;
    uint32_t                ringMode;   // 0 free running, 1 wrapped
    bool                    modeForced;
    bool                    open;
    uint64_t                rxDropped;
    uint32_t                baud;
    OSObject *              listener;   // QMXBridgeUserClient, retained
};

// ---------------------------------------------------------------------------

bool QMXSerialDriver::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(QMXSerialDriver_IVars, 1);
    if (!ivars) return false;
    ivars->lock = IOLockAlloc();
    ivars->baud = 115200;
    return ivars->lock != nullptr;
}

void QMXSerialDriver::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->rxMap);
        OSSafeReleaseNULL(ivars->txMap);
        OSSafeReleaseNULL(ivars->listener);
        if (ivars->lock) IOLockFree(ivars->lock);
    }
    IOSafeDeleteNULL(ivars, QMXSerialDriver_IVars, 1);
    super::free();
}

kern_return_t IMPL(QMXSerialDriver, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        LOG("super Start failed 0x%x", ret);
        return ret;
    }
    if (!gQMXLock) gQMXLock = IOLockAlloc();
    IOLockLock(gQMXLock);
    if (!gQMXSerial) { gQMXSerial = this; retain(); }
    IOLockUnlock(gQMXLock);

    ret = RegisterService();
    LOG("started (RegisterService 0x%x)", ret);
    return ret;
}

kern_return_t IMPL(QMXSerialDriver, Stop)
{
    if (gQMXLock) {
        IOLockLock(gQMXLock);
        if (gQMXSerial == this) { gQMXSerial = nullptr; release(); }
        IOLockUnlock(gQMXLock);
    }
    SetListener(nullptr);
    LOG("stopped");
    return Stop(provider, SUPERDISPATCH);
}

// ---------------------------------------------------------------------------
// rings

static uint8_t * MapDescriptor(IOMemoryDescriptor * md, IOMemoryMap ** mapOut)
{
    if (!md) return nullptr;
    IOMemoryMap * map = nullptr;
    if (md->CreateMapping(0, 0, 0, 0, 0, &map) != kIOReturnSuccess || !map) return nullptr;
    *mapOut = map;
    return reinterpret_cast<uint8_t *>(map->GetAddress());
}

kern_return_t IMPL(QMXSerialDriver, ConnectQueues)
{
    kern_return_t ret = ConnectQueues(ifmd, rxqmd, txqmd, in_rxqmd, in_txqmd,
                                      in_rxqoffset, in_txqoffset, in_rxqlogsz, in_txqlogsz,
                                      SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        LOG("super ConnectQueues failed 0x%x", ret);
        return ret;
    }
    IOAddressSegment seg = {};
    if (!ifmd || !*ifmd || (*ifmd)->GetAddressRange(&seg) != kIOReturnSuccess || !seg.address) {
        LOG("no interface block");
        return kIOReturnNoMemory;
    }
    IOLockLock(ivars->lock);
    OSSafeReleaseNULL(ivars->rxMap);
    OSSafeReleaseNULL(ivars->txMap);
    ivars->spi = reinterpret_cast<SerialPortInterface *>(seg.address);
    uint8_t * rx = MapDescriptor(rxqmd ? *rxqmd : nullptr, &ivars->rxMap);
    uint8_t * tx = MapDescriptor(txqmd ? *txqmd : nullptr, &ivars->txMap);
    SerialPortInterface * spi = ivars->spi;
    uint8_t rxlog = spi->rxqlogsz ? spi->rxqlogsz : in_rxqlogsz;
    uint8_t txlog = spi->txqlogsz ? spi->txqlogsz : in_txqlogsz;
    if (!rx || !tx || rxlog > driverkit::serial::kSerialQueueLogSizeMax ||
        txlog > driverkit::serial::kSerialQueueLogSizeMax) {
        LOG("ring mapping failed (rx %p tx %p log %u/%u)", rx, tx, rxlog, txlog);
        ivars->spi = nullptr;
        IOLockUnlock(ivars->lock);
        return kIOReturnNoMemory;
    }
    ivars->rxBase = rx + spi->rxqoffset;
    ivars->txBase = tx + spi->txqoffset;
    ivars->rxSize = 1u << rxlog;
    ivars->txSize = 1u << txlog;
    LOG("queues connected: rx %u bytes at +%u, tx %u bytes at +%u, PI/CI rx %u/%u tx %u/%u",
        ivars->rxSize, spi->rxqoffset, ivars->txSize, spi->txqoffset,
        spi->rxPI, spi->rxCI, spi->txPI, spi->txCI);
    IOLockUnlock(ivars->lock);
    SendEvent(kQMXEventQueues, 1);
    return kIOReturnSuccess;
}

kern_return_t IMPL(QMXSerialDriver, DisconnectQueues)
{
    IOLockLock(ivars->lock);
    ivars->spi = nullptr;
    ivars->rxBase = ivars->txBase = nullptr;
    OSSafeReleaseNULL(ivars->rxMap);
    OSSafeReleaseNULL(ivars->txMap);
    IOLockUnlock(ivars->lock);
    LOG("queues disconnected");
    SendEvent(kQMXEventQueues, 0);
    return DisconnectQueues(SUPERDISPATCH);
}

static inline uint32_t LoadIdx(const uint32_t * p) { return __atomic_load_n(p, __ATOMIC_ACQUIRE); }
static inline void StoreIdx(uint32_t * p, uint32_t v) { __atomic_store_n(p, v, __ATOMIC_RELEASE); }

// Seeing a kernel-owned index at or past the ring size means indices run free.
static void NoteIndex(QMXSerialDriver_IVars * iv, uint32_t idx, uint32_t size)
{
    if (idx >= size && iv->ringMode != 0 && !iv->modeForced) {
        iv->ringMode = 0;
        LOG("ring indices run free (saw %u with ring size %u): using free-running mode", idx, size);
    }
}

static inline uint32_t Used(uint32_t pi, uint32_t ci, uint32_t size, uint32_t mode)
{
    return mode == 0 ? (pi - ci) : ((pi - ci) & (size - 1));
}

static inline uint32_t Capacity(uint32_t size, uint32_t mode) { return mode == 0 ? size : size - 1; }

uint32_t QMXSerialDriver::PushRx(const uint8_t * data, uint32_t len)
{
    uint32_t done = 0;
    IOLockLock(ivars->lock);
    SerialPortInterface * spi = ivars->spi;
    if (spi && ivars->rxBase && ivars->open) {
        const uint32_t size = ivars->rxSize, mask = size - 1;
        uint32_t pi = spi->rxPI;                       // ours
        uint32_t ci = LoadIdx(&spi->rxCI);             // the kernel's
        NoteIndex(ivars, ci, size);
        const uint32_t mode = ivars->ringMode;
        uint32_t used = Used(pi, ci, size, mode);
        uint32_t room = used >= Capacity(size, mode) ? 0 : Capacity(size, mode) - used;
        uint32_t n = len < room ? len : room;
        while (done < n) {
            uint32_t pos = (pi + done) & mask;
            uint32_t chunk = size - pos;
            if (chunk > n - done) chunk = n - done;
            memcpy(ivars->rxBase + pos, data + done, chunk);
            done += chunk;
        }
        uint32_t npi = pi + done;
        if (mode == 1) npi &= mask;
        StoreIdx(&spi->rxPI, npi);
    }
    if (done < len) ivars->rxDropped += (len - done);
    IOLockUnlock(ivars->lock);
    if (done) RxDataAvailable();
    return done;
}

uint32_t QMXSerialDriver::PullTx(uint8_t * out, uint32_t max)
{
    uint32_t done = 0;
    IOLockLock(ivars->lock);
    SerialPortInterface * spi = ivars->spi;
    if (spi && ivars->txBase) {
        const uint32_t size = ivars->txSize, mask = size - 1;
        uint32_t pi = LoadIdx(&spi->txPI);             // the kernel's
        uint32_t ci = spi->txCI;                       // ours
        NoteIndex(ivars, pi, size);
        NoteIndex(ivars, ci, size);
        const uint32_t mode = ivars->ringMode;
        uint32_t avail = Used(pi, ci, size, mode);
        if (avail > size) avail = 0;                   // inconsistent: treat as empty
        uint32_t n = avail < max ? avail : max;
        while (done < n) {
            uint32_t pos = (ci + done) & mask;
            uint32_t chunk = size - pos;
            if (chunk > n - done) chunk = n - done;
            memcpy(out + done, ivars->txBase + pos, chunk);
            done += chunk;
        }
        uint32_t nci = ci + done;
        if (mode == 1) nci &= mask;
        StoreIdx(&spi->txCI, nci);
    }
    IOLockUnlock(ivars->lock);
    if (done) TxFreeSpaceAvailable();
    return done;
}

void QMXSerialDriver::FlushRx()
{
    // Radio bytes the program has not read stay in the kernel's buffer; nothing to
    // do on our side beyond counting. The serial family flushes on close.
}

void QMXSerialDriver::SetRingMode(uint32_t mode)
{
    IOLockLock(ivars->lock);
    ivars->ringMode = mode ? 1 : 0;
    ivars->modeForced = true;
    IOLockUnlock(ivars->lock);
    LOG("ring mode set to %u by the app", mode ? 1 : 0);
}

void QMXSerialDriver::GetStatus(uint64_t * out, uint32_t count)
{
    uint64_t s[kQMXStatCount] = {};
    IOLockLock(ivars->lock);
    s[kQMXStatPortReady] = 1;
    s[kQMXStatOpen] = ivars->open;
    s[kQMXStatQueues] = ivars->spi != nullptr;
    s[kQMXStatRxSize] = ivars->rxSize;
    s[kQMXStatTxSize] = ivars->txSize;
    s[kQMXStatRxDropped] = ivars->rxDropped;
    s[kQMXStatBaud] = ivars->baud;
    s[kQMXStatRingMode] = ivars->ringMode;
    IOLockUnlock(ivars->lock);
    for (uint32_t i = 0; i < count && i < kQMXStatCount; i++) out[i] = s[i];
}

void QMXSerialDriver::SetListener(OSObject * client)
{
    IOLockLock(ivars->lock);
    OSObject * old = ivars->listener;
    ivars->listener = client;
    if (client) client->retain();
    IOLockUnlock(ivars->lock);
    OSSafeReleaseNULL(old);
}

void QMXSerialDriver::SendEvent(uint64_t event, uint64_t value)
{
    IOLockLock(ivars->lock);
    OSObject * l = ivars->listener;
    if (l) l->retain();
    IOLockUnlock(ivars->lock);
    if (!l) return;
    QMXBridgeUserClient * uc = OSDynamicCast(QMXBridgeUserClient, l);
    if (uc) uc->Event(event, value);
    l->release();
}

// ---------------------------------------------------------------------------
// events from the serial family

void IMPL(QMXSerialDriver, TxDataAvailable)
{
    // The program wrote something: the app pulls it with kQMXMethodRead.
    SendEvent(kQMXEventTxData, 0);
}

void IMPL(QMXSerialDriver, RxFreeSpaceAvailable)
{
    // The program read some radio bytes. Nothing is queued here (the app's own
    // buffering decides what to drop), so there is nothing to resume.
}

kern_return_t IMPL(QMXSerialDriver, HwActivate)
{
    kern_return_t ret = HwActivate(SUPERDISPATCH);
    IOLockLock(ivars->lock);
    ivars->open = true;
    IOLockUnlock(ivars->lock);
    // A cable that is always plugged in: CTS, DSR and carrier on.
    SetModemStatus(true, true, false, true);
    LOG("port opened");
    SendEvent(kQMXEventOpen, 1);
    return ret;
}

kern_return_t IMPL(QMXSerialDriver, HwDeactivate)
{
    IOLockLock(ivars->lock);
    ivars->open = false;
    IOLockUnlock(ivars->lock);
    LOG("port closed");
    SendEvent(kQMXEventClose, 0);
    return HwDeactivate(SUPERDISPATCH);
}

kern_return_t IMPL(QMXSerialDriver, HwResetFIFO)
{
    return kIOReturnSuccess;
}

kern_return_t IMPL(QMXSerialDriver, HwSendBreak)
{
    return kIOReturnSuccess;
}

kern_return_t IMPL(QMXSerialDriver, HwProgramUART)
{
    IOLockLock(ivars->lock);
    ivars->baud = baudRate;               // any baud rate works; the setting is ignored
    IOLockUnlock(ivars->lock);
    return kIOReturnSuccess;
}

kern_return_t IMPL(QMXSerialDriver, HwProgramBaudRate)
{
    IOLockLock(ivars->lock);
    ivars->baud = baudRate;
    IOLockUnlock(ivars->lock);
    return kIOReturnSuccess;
}

kern_return_t IMPL(QMXSerialDriver, HwProgramMCR)
{
    SendEvent(kQMXEventMCR, (dtr ? 1 : 0) | (rts ? 2 : 0));
    return kIOReturnSuccess;
}

kern_return_t IMPL(QMXSerialDriver, HwGetModemStatus)
{
    if (cts) *cts = true;
    if (dsr) *dsr = true;
    if (ri)  *ri  = false;
    if (dcd) *dcd = true;
    return kIOReturnSuccess;
}

kern_return_t IMPL(QMXSerialDriver, HwProgramLatencyTimer)
{
    return kIOReturnSuccess;
}

kern_return_t IMPL(QMXSerialDriver, HwProgramFlowControl)
{
    return kIOReturnSuccess;
}
