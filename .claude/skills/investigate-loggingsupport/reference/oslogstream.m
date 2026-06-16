// oslogstream.m — stream live, structured os_log events from a physical iPhone
// using Apple's private LoggingSupport.framework (the engine Console.app/Xcode use).
//
// PROVEN against iPhone 12, iOS 26.5 (macOS 26 host), 2026-06: 14,158 structured lines in 10s,
// level distribution 11377 Debug / 1351 Default / 1308 Info / 164 Error — passive, no app launch,
// no device-unlock. This is the reference for Jaca's IOSDevice os_log source; if a macOS/Xcode
// upgrade breaks it, follow ../SKILL.md to re-derive the selectors/flags and patch this file.
//
// WORKING CHAIN:
//   1. MobileDevice: AMDCreateDeviceList() -> match AMDeviceCopyDeviceIdentifier == UDID; AMDeviceConnect.
//   2. id dev    = [[OSLogDevice alloc] initWithMobileDevice:amDeviceRef andUDID:@"<UDID>"];
//   3. id stream = [[OSActivityStream alloc] init];   // NOT initWithDevice: (that overload wants void*)
//      [stream setDevice:dev];                        // setDevice: (object) stores the OSLogDevice
//      [stream setDelegate:delegate]; [stream setDeviceDelegate:delegate];
//      [stream setOptions:(INFO|DEBUG|PAYLOAD)];      // os_activity_stream flags
//      [stream setEventFilter:0xFFFFFFFF];            // all activity-stream event types
//      [stream startRemote];                          // do NOT call establishTrust: (internal; crashes if misused)
//   4. Events arrive on the delegate: -activityStream:results: (array of OSActivityLogMessageEvent).
//      Read structured fields: messageType (level), subsystem, category, process, processID,
//      eventMessage, timestamp, sender.
//
// Compile:
//   clang -fobjc-arc -framework Foundation -framework CoreFoundation \
//     -Wno-objc-method-access -o /tmp/oslogstream oslogstream.m
// Run:
//   /tmp/oslogstream <UDID> [seconds]
//
// Both private frameworks are dlopen'd at runtime (no .tbd stubs needed):
//   - MobileDevice.framework  : AMDevice* C API (dlsym'd)
//   - LoggingSupport.framework: OSLog*/OSActivityStream classes (objc_getClass + objc_msgSend)

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - MobileDevice C API (resolved via dlsym)

typedef void *AMDeviceRef;
static AMDeviceRef *(*AMDCreateDeviceList)(void);
static int (*AMDeviceConnect)(AMDeviceRef);
static int (*AMDeviceIsPaired)(AMDeviceRef);
static CFStringRef (*AMDeviceCopyDeviceIdentifier)(AMDeviceRef);

static void *loadFW(const char *path) {
    void *h = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    if (!h) { fprintf(stderr, "dlopen failed: %s -> %s\n", path, dlerror()); exit(2); }
    return h;
}
#define SYM(h, name) do { name = dlsym(h, #name); \
    if (!name) fprintf(stderr, "dlsym failed: %s\n", #name); } while (0)

#pragma mark - os_activity_stream flags (reverse-engineered activity_stream_private.h)

enum {
    OS_ACTIVITY_STREAM_PROCESS_ONLY        = 0x00000001,
    OS_ACTIVITY_STREAM_SKIP_DECODE         = 0x00000002,
    OS_ACTIVITY_STREAM_PAYLOAD             = 0x00000004,
    OS_ACTIVITY_STREAM_HISTORICAL          = 0x00000008,
    OS_ACTIVITY_STREAM_CALLSTACK           = 0x00000010,
    OS_ACTIVITY_STREAM_DEBUG               = 0x00000020,
    OS_ACTIVITY_STREAM_BUFFERED            = 0x00000040,
    OS_ACTIVITY_STREAM_NO_SENSITIVE        = 0x00000080,
    OS_ACTIVITY_STREAM_INFO                = 0x00000100,
    OS_ACTIVITY_STREAM_PROMISCUOUS         = 0x00000200,
    OS_ACTIVITY_STREAM_PRECISE_TIMESTAMPS  = 0x00000400,
};

#pragma mark - messageType -> level name (OSActivityLogMessageEvent.messageType, unsigned char)

static const char *levelName(unsigned char t) {
    switch (t) {
        case 0x00: return "Default";
        case 0x01: return "Info";
        case 0x02: return "Debug";
        case 0x10: return "Error";
        case 0x11: return "Fault";
        default:   return "?";
    }
}

#pragma mark - read OSActivityEvent / OSActivityLogMessageEvent structured fields

static NSString *strProp(id e, const char *sel) {
    SEL s = sel_getUid(sel);
    if (![e respondsToSelector:s]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(e, s);
    if (!v) return nil;
    return [v isKindOfClass:[NSString class]] ? v : [v description];
}

static long g_count = 0;

static void printEvent(id e) {
    if (!e) return;
    // Only log/trace messages carry subsystem/category/messageType; skip activity/statedump noise.
    BOOL isMsg = [e respondsToSelector:sel_getUid("messageType")];
    if (!isMsg) return; // not an OSActivityEventMessage subclass

    unsigned char mt = ((unsigned char (*)(id, SEL))objc_msgSend)(e, sel_getUid("messageType"));
    NSString *subsystem = strProp(e, "subsystem");
    NSString *category  = strProp(e, "category");
    NSString *process   = strProp(e, "process");
    NSString *sender    = strProp(e, "sender");
    // eventMessage = the fully composed, decoded message (format string is nil once PAYLOAD-decoded).
    NSString *msg       = strProp(e, "eventMessage");
    if (!msg) msg = strProp(e, "format");
    int pid = ((int (*)(id, SEL))objc_msgSend)(e, sel_getUid("processID"));
    id ts = ((id (*)(id, SEL))objc_msgSend)(e, sel_getUid("timestamp"));
    g_count++;
    printf("%-31s %-7s %s[%d] <%s> {%s/%s} %s\n",
           ts ? [[ts description] UTF8String] : "-",
           levelName(mt),
           process.length ? process.UTF8String : "-", pid,
           sender.length ? sender.UTF8String : "-",
           subsystem.length ? subsystem.UTF8String : "-",
           category.length  ? category.UTF8String  : "-",
           msg ? msg.UTF8String : "");
    fflush(stdout);
}

#pragma mark - OSActivityStreamDelegate

@interface StreamDelegate : NSObject
@end
@implementation StreamDelegate
- (void)activityStream:(id)s deviceUDID:(id)udid deviceID:(id)devID status:(long long)status error:(id)err {
    fprintf(stderr, "[status] udid=%s deviceID=%s status=%lld err=%s\n",
            [[udid description] UTF8String], [[devID description] UTF8String],
            status, err ? [[err description] UTF8String] : "nil");
}
- (void)activityStream:(id)s results:(NSArray *)results {
    for (id e in results) printEvent(e);
}
- (void)activityStream:(id)s results:(NSArray *)results error:(id)err {
    if (err) fprintf(stderr, "[results err] %s\n", [[err description] UTF8String]);
    for (id e in results) printEvent(e);
}
- (void)streamDidFail:(id)s error:(id)err {
    fprintf(stderr, "[fail] %s\n", err ? [[err description] UTF8String] : "nil");
}
@end

#pragma mark - main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: %s <UDID> [seconds]\n", argv[0]); return 1; }
        NSString *udid = [NSString stringWithUTF8String:argv[1]];
        double seconds = argc >= 3 ? atof(argv[2]) : 15.0;

        // 1) Load private frameworks.
        void *mdH = loadFW("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice");
        loadFW("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport");
        SYM(mdH, AMDCreateDeviceList);
        SYM(mdH, AMDeviceConnect);
        SYM(mdH, AMDeviceIsPaired);
        SYM(mdH, AMDeviceCopyDeviceIdentifier);

        // 2) Find the AMDeviceRef matching the UDID, connect.
        CFArrayRef arr = (CFArrayRef)AMDCreateDeviceList();
        AMDeviceRef match = NULL;
        if (arr) {
            for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
                AMDeviceRef d = (AMDeviceRef)CFArrayGetValueAtIndex(arr, i);
                NSString *s = (__bridge_transfer NSString *)AMDeviceCopyDeviceIdentifier(d);
                if ([s isEqualToString:udid]) match = d;
            }
        }
        if (!match) { fprintf(stderr, "[mobiledevice] UDID %s not found\n", udid.UTF8String); return 4; }
        fprintf(stderr, "[mobiledevice] matched %s  isPaired=%d connect=%d\n",
                udid.UTF8String, AMDeviceIsPaired(match), AMDeviceConnect(match));

        // 3) OSLogDevice from the AMDeviceRef.
        Class OSLogDevice      = objc_getClass("OSLogDevice");
        Class OSActivityStream = objc_getClass("OSActivityStream");
        if (!OSLogDevice || !OSActivityStream) { fprintf(stderr, "missing classes\n"); return 5; }

        id dev = ((id (*)(id, SEL))objc_msgSend)((id)OSLogDevice, sel_getUid("alloc"));
        dev = ((id (*)(id, SEL, void *, id))objc_msgSend)(dev, sel_getUid("initWithMobileDevice:andUDID:"), match, udid);
        if (!dev) { fprintf(stderr, "OSLogDevice init failed\n"); return 6; }

        // 4) OSActivityStream: init -> setDevice: -> setDelegate: -> options/filter -> startRemote.
        id stream = ((id (*)(id, SEL))objc_msgSend)((id)OSActivityStream, sel_getUid("alloc"));
        stream = ((id (*)(id, SEL))objc_msgSend)(stream, sel_getUid("init"));
        ((void (*)(id, SEL, id))objc_msgSend)(stream, sel_getUid("setDevice:"), dev);

        StreamDelegate *delegate = [StreamDelegate new];
        ((void (*)(id, SEL, id))objc_msgSend)(stream, sel_getUid("setDelegate:"), delegate);
        ((void (*)(id, SEL, id))objc_msgSend)(stream, sel_getUid("setDeviceDelegate:"), delegate);

        // INFO + DEBUG + PAYLOAD (decoded messages). NO_SENSITIVE left OFF so values
        // come through where the device's privacy policy allows.
        unsigned long long options = OS_ACTIVITY_STREAM_INFO | OS_ACTIVITY_STREAM_DEBUG | OS_ACTIVITY_STREAM_PAYLOAD;
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(stream, sel_getUid("setOptions:"), options);
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(stream, sel_getUid("setEventFilter:"), 0xFFFFFFFFULL);

        fprintf(stderr, "[oslog] startRemote, streaming %.0fs (options=0x%llx)\n", seconds, options);
        ((void (*)(id, SEL))objc_msgSend)(stream, sel_getUid("startRemote"));

        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
        ((void (*)(id, SEL))objc_msgSend)(stream, sel_getUid("stopRemote"));
        fprintf(stderr, "[oslog] done. %ld events.\n", g_count);
    }
    return 0;
}
