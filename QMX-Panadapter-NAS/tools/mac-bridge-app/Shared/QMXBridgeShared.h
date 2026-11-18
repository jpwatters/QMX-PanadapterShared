// QMXBridgeShared.h - the contract between the QMX Bridge app and its driver
// (QMXSerialDriver.dext). Included by the dext (C++) and the app (Swift, via
// the bridging header).

#ifndef QMXBridgeShared_h
#define QMXBridgeShared_h

#include <stdint.h>

// IOService class name the app looks up, and the user client type it opens.
#define kQMXBridgeControlClass   "QMXBridgeControl"
#define kQMXBridgeUserClientType 0x514D58u            // 'QMX'

// The BSD name programs see: /dev/cu.<IOTTYBaseName><IOTTYSuffix>
#define kQMXSerialTTYBaseName    "QMX-NAS"

// External methods on the user client.
enum {
    // structure input: bytes from the radio, delivered to the program reading the port (<= 4096)
    kQMXMethodWrite      = 0,
    // structure output: bytes the program wrote to the port (<= 4096); empty = none waiting
    kQMXMethodRead       = 1,
    // async: register for notifications (completion args below); no input
    kQMXMethodNotify     = 2,
    // scalar output[0..7]: state, see kQMXStat*
    kQMXMethodStatus     = 3,
    // scalar input[0]: ring index mode (0 = free running, 1 = wrapped at ring size)
    kQMXMethodSetRingMode = 4,
    // no input: throw away radio bytes not yet read by the program
    kQMXMethodFlushRx    = 5,
    kQMXMethodCount
};

// Async completion argument 0: what happened. Argument 1: a value.
enum {
    kQMXEventTxData  = 1,   // the program wrote bytes: call kQMXMethodRead until it returns none
    kQMXEventOpen    = 2,   // a program opened the port (HwActivate)
    kQMXEventClose   = 3,   // the port was closed (HwDeactivate)
    kQMXEventMCR     = 4,   // DTR/RTS changed: value bit0 = DTR, bit1 = RTS
    kQMXEventQueues  = 5,   // ring buffers connected (value 1) or disconnected (value 0)
};

// kQMXMethodStatus outputs
enum {
    kQMXStatPortReady = 0,  // 1 = the serial driver instance exists
    kQMXStatOpen      = 1,  // 1 = a program has the port open
    kQMXStatQueues    = 2,  // 1 = rings connected
    kQMXStatRxSize    = 3,  // rx ring size (bytes)
    kQMXStatTxSize    = 4,
    kQMXStatRxDropped = 5,  // radio bytes dropped because the program did not read them
    kQMXStatBaud      = 6,  // last baud rate the program set (ignored)
    kQMXStatRingMode  = 7,
    kQMXStatCount     = 8
};

#endif /* QMXBridgeShared_h */
