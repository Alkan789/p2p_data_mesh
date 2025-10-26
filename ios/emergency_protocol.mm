#import <Foundation/Foundation.h>
#import "emergency_protocol.h"
#import <os/log.h>

void emergency_protocol_init() {
    os_log_info(OS_LOG_DEFAULT, "Emergency protocol init (iOS)");
}

int emergency_send_broadcast(const char* message) {
    NSString *msg = message ? [NSString stringWithUTF8String:message] : @"";
    os_log_info(OS_LOG_DEFAULT, "iOS send broadcast: %{public}s", message);
    // Burada gerçek CoreBluetooth gönderimi / native iOS kodunu çağırabilirsin.
    return 0;
}

int emergency_start_discovery() {
    os_log_info(OS_LOG_DEFAULT, "iOS start discovery");
    return 0;
}

int emergency_stop_discovery() {
    os_log_info(OS_LOG_DEFAULT, "iOS stop discovery");
    return 0;
}
