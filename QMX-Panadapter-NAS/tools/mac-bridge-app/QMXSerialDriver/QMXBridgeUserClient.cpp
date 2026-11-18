// QMXBridgeUserClient.cpp - methods the QMX Bridge app calls on the virtual
// serial port (see Shared/QMXBridgeShared.h).

#include <os/log.h>
#include <DriverKit/DriverKit.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/OSAction.h>
#include <DriverKit/OSData.h>

#include "QMXBridgeUserClient.h"
#include "QMXSerialDriver.h"
#include "../Shared/QMXBridgeShared.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "QMXBridgeUserClient: " fmt, ##__VA_ARGS__)

extern IOLock *          gQMXLock;
extern QMXSerialDriver * gQMXSerial;

struct QMXBridgeUserClient_IVars {
    IOLock *   lock;
    OSAction * notify;      // the app's async callback, retained
};

// The serial port instance, retained; nullptr if the driver hasn't started.
static QMXSerialDriver * CopySerial()
{
    if (!gQMXLock) return nullptr;
    IOLockLock(gQMXLock);
    QMXSerialDriver * s = gQMXSerial;
    if (s) s->retain();
    IOLockUnlock(gQMXLock);
    return s;
}

bool QMXBridgeUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(QMXBridgeUserClient_IVars, 1);
    if (!ivars) return false;
    ivars->lock = IOLockAlloc();
    return ivars->lock != nullptr;
}

void QMXBridgeUserClient::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->notify);
        if (ivars->lock) IOLockFree(ivars->lock);
    }
    IOSafeDeleteNULL(ivars, QMXBridgeUserClient_IVars, 1);
    super::free();
}

kern_return_t IMPL(QMXBridgeUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    if (QMXSerialDriver * s = CopySerial()) {
        s->SetListener(this);
        s->release();
    }
    LOG("app connected");
    return kIOReturnSuccess;
}

kern_return_t IMPL(QMXBridgeUserClient, Stop)
{
    if (QMXSerialDriver * s = CopySerial()) {
        s->SetListener(nullptr);
        s->release();
    }
    IOLockLock(ivars->lock);
    OSAction * a = ivars->notify;
    ivars->notify = nullptr;
    IOLockUnlock(ivars->lock);
    OSSafeReleaseNULL(a);
    LOG("app disconnected");
    return Stop(provider, SUPERDISPATCH);
}

void QMXBridgeUserClient::Event(uint64_t event, uint64_t value)
{
    IOLockLock(ivars->lock);
    OSAction * a = ivars->notify;
    if (a) a->retain();
    IOLockUnlock(ivars->lock);
    if (!a) return;
    uint64_t args[2] = { event, value };
    AsyncCompletion(a, kIOReturnSuccess, args, 2);
    a->release();
}

kern_return_t QMXBridgeUserClient::ExternalMethod(uint64_t selector,
                                                  IOUserClientMethodArguments * args,
                                                  const IOUserClientMethodDispatch * dispatch,
                                                  OSObject * target,
                                                  void * reference)
{
    (void)dispatch; (void)target; (void)reference;
    QMXSerialDriver * s = CopySerial();
    kern_return_t ret = kIOReturnSuccess;

    switch (selector) {
    case kQMXMethodWrite: {
        if (!s) { ret = kIOReturnNotReady; break; }
        OSData * in = args->structureInput;
        uint32_t accepted = 0;
        if (in && in->getLength()) {
            accepted = s->PushRx(static_cast<const uint8_t *>(in->getBytesNoCopy()),
                                 static_cast<uint32_t>(in->getLength()));
        }
        if (args->scalarOutput && args->scalarOutputCount >= 1) {
            args->scalarOutput[0] = accepted;
            args->scalarOutputCount = 1;
        }
        break;
    }
    case kQMXMethodRead: {
        if (!s) { ret = kIOReturnNotReady; break; }
        uint8_t buf[4096];
        uint32_t max = sizeof(buf);
        if (args->structureOutputMaximumSize && args->structureOutputMaximumSize < max)
            max = static_cast<uint32_t>(args->structureOutputMaximumSize);
        uint32_t n = s->PullTx(buf, max);
        args->structureOutput = OSData::withBytes(buf, n);
        break;
    }
    case kQMXMethodNotify: {
        if (!args->completion) { ret = kIOReturnBadArgument; break; }
        args->completion->retain();
        IOLockLock(ivars->lock);
        OSAction * old = ivars->notify;
        ivars->notify = args->completion;
        IOLockUnlock(ivars->lock);
        OSSafeReleaseNULL(old);
        if (s) s->SetListener(this);
        break;
    }
    case kQMXMethodStatus: {
        uint64_t st[kQMXStatCount] = {};
        if (s) s->GetStatus(st, kQMXStatCount);
        if (args->scalarOutput) {
            uint32_t n = args->scalarOutputCount < kQMXStatCount ? args->scalarOutputCount : kQMXStatCount;
            for (uint32_t i = 0; i < n; i++) args->scalarOutput[i] = st[i];
            args->scalarOutputCount = n;
        }
        break;
    }
    case kQMXMethodSetRingMode: {
        if (!s) { ret = kIOReturnNotReady; break; }
        if (!args->scalarInput || args->scalarInputCount < 1) { ret = kIOReturnBadArgument; break; }
        s->SetRingMode(static_cast<uint32_t>(args->scalarInput[0]));
        break;
    }
    case kQMXMethodFlushRx: {
        if (s) s->FlushRx();
        break;
    }
    default:
        ret = kIOReturnBadArgument;
        break;
    }
    if (s) s->release();
    return ret;
}
