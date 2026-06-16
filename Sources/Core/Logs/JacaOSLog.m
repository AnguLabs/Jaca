#import "JacaOSLog.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// MARK: - MobileDevice C API (resolved via dlsym; void* handle = AMDeviceRef)

typedef void *AMDeviceRef;
static AMDeviceRef *(*gAMDCreateDeviceList)(void);
static int (*gAMDeviceConnect)(AMDeviceRef);
static CFStringRef (*gAMDeviceCopyDeviceIdentifier)(AMDeviceRef);
static BOOL gLoaded = NO;
static BOOL gLoadOK = NO;

// os_activity_stream option flags (reverse-engineered; see investigate-loggingsupport skill).
enum {
    OS_ACTIVITY_STREAM_PAYLOAD = 0x00000004,
    OS_ACTIVITY_STREAM_DEBUG   = 0x00000020,
    OS_ACTIVITY_STREAM_INFO    = 0x00000100,
};

/// Loads MobileDevice + LoggingSupport once and resolves the AMDevice symbols and
/// the OSLog classes. Returns NO if anything is missing on this OS/Xcode build.
static BOOL JacaLoadPrivateAPIs(void) {
    if (gLoaded) return gLoadOK;
    gLoaded = YES;
    void *md = dlopen("/Library/Apple/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice", RTLD_NOW | RTLD_GLOBAL);
    void *ls = dlopen("/System/Library/PrivateFrameworks/LoggingSupport.framework/LoggingSupport", RTLD_NOW | RTLD_GLOBAL);
    if (!md || !ls) return NO;
    gAMDCreateDeviceList          = dlsym(md, "AMDCreateDeviceList");
    gAMDeviceConnect              = dlsym(md, "AMDeviceConnect");
    gAMDeviceCopyDeviceIdentifier = dlsym(md, "AMDeviceCopyDeviceIdentifier");
    if (!gAMDCreateDeviceList || !gAMDeviceConnect || !gAMDeviceCopyDeviceIdentifier) return NO;
    if (!objc_getClass("OSLogDevice") || !objc_getClass("OSActivityStream")) return NO;
    gLoadOK = YES;
    return YES;
}

// MARK: - JacaOSLogEvent

@interface JacaOSLogEvent ()
- (instancetype)initWithLevel:(unsigned char)level pid:(int)pid timestamp:(double)ts
                      process:(nullable NSString *)process sender:(nullable NSString *)sender
                    subsystem:(nullable NSString *)subsystem category:(nullable NSString *)category
                      message:(nullable NSString *)message;
@end

@implementation JacaOSLogEvent
- (instancetype)initWithLevel:(unsigned char)level pid:(int)pid timestamp:(double)ts
                      process:(NSString *)process sender:(NSString *)sender
                    subsystem:(NSString *)subsystem category:(NSString *)category
                      message:(NSString *)message {
    if (!(self = [super init])) return nil;
    _level = level; _processID = pid; _timestamp = ts;
    _process = [process copy]; _sender = [sender copy];
    _subsystem = [subsystem copy]; _category = [category copy]; _message = [message copy];
    return self;
}
@end

// MARK: - field extraction off OSActivityLogMessageEvent (via objc runtime)

static NSString *JacaStr(id e, const char *sel) {
    SEL s = sel_getUid(sel);
    if (![e respondsToSelector:s]) return nil;
    id v = ((id (*)(id, SEL))objc_msgSend)(e, s);
    if (!v) return nil;
    return [v isKindOfClass:[NSString class]] ? v : [v description];
}

// MARK: - JacaOSLogStream

@interface JacaOSLogStream ()
@property (nonatomic, copy) NSString *udid;
@property (nonatomic, copy) void (^onEvent)(JacaOSLogEvent *);
@property (nonatomic) AMDeviceRef amDevice;     // void* — not ARC-managed
@property (nonatomic, strong) id device;        // OSLogDevice
@property (nonatomic, strong) id stream;        // OSActivityStream
@property (nonatomic, strong) NSThread *thread;
@property (nonatomic) BOOL running;
@end

@implementation JacaOSLogStream

+ (BOOL)isAvailable { return JacaLoadPrivateAPIs(); }

- (instancetype)initWithUDID:(NSString *)udid onEvent:(void (^)(JacaOSLogEvent *))onEvent {
    if (!(self = [super init])) return nil;
    if (!JacaLoadPrivateAPIs()) return nil;
    _udid = [udid copy];
    _onEvent = [onEvent copy];

    // Find the AMDeviceRef for this UDID and connect.
    CFArrayRef arr = (CFArrayRef)gAMDCreateDeviceList();
    AMDeviceRef match = NULL;
    if (arr) {
        for (CFIndex i = 0; i < CFArrayGetCount(arr); i++) {
            AMDeviceRef d = (AMDeviceRef)CFArrayGetValueAtIndex(arr, i);
            NSString *ident = (__bridge_transfer NSString *)gAMDeviceCopyDeviceIdentifier(d);
            if ([ident isEqualToString:udid]) match = d;
        }
    }
    if (!match) return nil;
    gAMDeviceConnect(match);
    _amDevice = match;

    // OSLogDevice from the AMDeviceRef.
    Class OSLogDevice = objc_getClass("OSLogDevice");
    id dev = ((id (*)(id, SEL))objc_msgSend)((id)OSLogDevice, sel_getUid("alloc"));
    dev = ((id (*)(id, SEL, void *, id))objc_msgSend)(dev, sel_getUid("initWithMobileDevice:andUDID:"), match, udid);
    if (!dev) return nil;
    _device = dev;
    return self;
}

- (BOOL)start {
    if (_thread) return YES;
    if (!_device) return NO;
    _running = YES;
    _thread = [[NSThread alloc] initWithTarget:self selector:@selector(runStream) object:nil];
    _thread.name = @"dev.srsouza.Jaca.oslog";
    [_thread start];
    return YES;
}

- (void)runStream {
    @autoreleasepool {
        Class OSActivityStream = objc_getClass("OSActivityStream");
        // init -> setDevice: -> setDelegate: -> options/filter -> startRemote
        id s = ((id (*)(id, SEL))objc_msgSend)((id)OSActivityStream, sel_getUid("alloc"));
        s = ((id (*)(id, SEL))objc_msgSend)(s, sel_getUid("init"));
        if (!s) return;
        ((void (*)(id, SEL, id))objc_msgSend)(s, sel_getUid("setDevice:"), _device);
        ((void (*)(id, SEL, id))objc_msgSend)(s, sel_getUid("setDelegate:"), self);
        ((void (*)(id, SEL, id))objc_msgSend)(s, sel_getUid("setDeviceDelegate:"), self);
        unsigned long long options = OS_ACTIVITY_STREAM_INFO | OS_ACTIVITY_STREAM_DEBUG | OS_ACTIVITY_STREAM_PAYLOAD;
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(s, sel_getUid("setOptions:"), options);
        ((void (*)(id, SEL, unsigned long long))objc_msgSend)(s, sel_getUid("setEventFilter:"), 0xFFFFFFFFULL);
        _stream = s;
        // startRemote performs the trust handshake + opens com.apple.os_trace_relay.
        ((void (*)(id, SEL))objc_msgSend)(s, sel_getUid("startRemote"));

        // Keep this thread + its runloop alive while streaming (mirrors the proven
        // prototype). Delivery itself is on OSActivityStream's own queue.
        while (_running) {
            [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        }
        ((void (*)(id, SEL))objc_msgSend)(s, sel_getUid("stopRemote"));
        _stream = nil;
    }
}

- (void)stop {
    _running = NO;
    [_thread cancel];
    _thread = nil;
}

// MARK: OSActivityStreamDelegate (typed loosely; the runtime dispatches by selector)

- (void)activityStream:(id)stream results:(NSArray *)results {
    [self handleResults:results];
}
- (void)activityStream:(id)stream results:(NSArray *)results error:(id)error {
    [self handleResults:results];
}
- (void)activityStream:(id)stream deviceUDID:(id)udid deviceID:(id)devID status:(long long)status error:(id)error {
    // connection/status callback — nothing to surface for now.
}

- (void)handleResults:(NSArray *)results {
    void (^cb)(JacaOSLogEvent *) = self.onEvent;
    if (!cb) return;
    for (id e in results) {
        // Only log/trace messages carry messageType/subsystem/category.
        if (![e respondsToSelector:sel_getUid("messageType")]) continue;
        unsigned char mt = ((unsigned char (*)(id, SEL))objc_msgSend)(e, sel_getUid("messageType"));
        int pid = 0;
        if ([e respondsToSelector:sel_getUid("processID")])
            pid = ((int (*)(id, SEL))objc_msgSend)(e, sel_getUid("processID"));
        double ts = 0;
        if ([e respondsToSelector:sel_getUid("timestamp")]) {
            id d = ((id (*)(id, SEL))objc_msgSend)(e, sel_getUid("timestamp"));
            if ([d isKindOfClass:[NSDate class]]) ts = [(NSDate *)d timeIntervalSince1970];
        }
        NSString *msg = JacaStr(e, "eventMessage");
        if (!msg) msg = JacaStr(e, "format");
        JacaOSLogEvent *ev = [[JacaOSLogEvent alloc] initWithLevel:mt pid:pid timestamp:ts
                                                           process:JacaStr(e, "process")
                                                            sender:JacaStr(e, "sender")
                                                         subsystem:JacaStr(e, "subsystem")
                                                          category:JacaStr(e, "category")
                                                           message:msg];
        cb(ev);
    }
}

@end
