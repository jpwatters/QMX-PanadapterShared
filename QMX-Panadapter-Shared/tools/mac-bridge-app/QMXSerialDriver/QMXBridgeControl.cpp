// QMXBridgeControl.cpp - the service the app opens; it hands out
// QMXBridgeUserClient connections (one per app).

#include <os/log.h>
#include <DriverKit/DriverKit.h>
#include <DriverKit/IOUserClient.h>

#include "QMXBridgeControl.h"
#include "../Shared/QMXBridgeShared.h"

#define LOG(fmt, ...) os_log(OS_LOG_DEFAULT, "QMXBridgeControl: " fmt, ##__VA_ARGS__)

kern_return_t IMPL(QMXBridgeControl, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;
    ret = RegisterService();
    LOG("started (RegisterService 0x%x)", ret);
    return ret;
}

kern_return_t IMPL(QMXBridgeControl, Stop)
{
    LOG("stopped");
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t IMPL(QMXBridgeControl, NewUserClient)
{
    if (type != kQMXBridgeUserClientType) {
        LOG("refused user client type 0x%x", type);
        return kIOReturnBadArgument;
    }
    IOService * client = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess || !client) {
        LOG("Create user client failed 0x%x", ret);
        return ret != kIOReturnSuccess ? ret : kIOReturnNoMemory;
    }
    *userClient = OSDynamicCast(IOUserClient, client);
    if (!*userClient) {
        client->release();
        return kIOReturnError;
    }
    return kIOReturnSuccess;
}
