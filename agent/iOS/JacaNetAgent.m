// JacaNetAgent.m — in-process network capture for iOS Simulator apps, no CA / no proxy.
//
// Injected into a debug app via SIMCTL_CHILD_DYLD_INSERT_LIBRARIES (set by Jaca when it
// launches the app on the simulator). On load it connects back to Jaca on
// 127.0.0.1:$JACA_NET_PORT (the simulator shares the Mac's loopback) and registers an
// NSURLProtocol that taps the URL-loading system. Every request is replayed through a
// private session (so we see plaintext request+response, before/after TLS) and reported
// as one newline-delimited JSON line per completed request — the SAME schema Jaca's
// AgentTransactionParser already parses for the Android agent.
//
// Build (Jaca's project.yml postBuildScript does this into Jaca.app/Contents/Resources):
//   xcrun -sdk iphonesimulator clang -dynamiclib -fobjc-arc \
//     -target arm64-apple-ios15.0-simulator -framework Foundation -o JacaNetAgent.dylib JacaNetAgent.m

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

#pragma mark - Reporting channel (one TCP connection back to Jaca, newline-JSON frames)

static int gSock = -1;
static dispatch_queue_t gQueue;          // serializes connect + writes
static BOOL gConnected = NO;

static void connectOnce(void) {
    if (gConnected) return;
    const char *p = getenv("JACA_NET_PORT");
    if (!p) return;
    int port = atoi(p);
    if (port <= 0) return;
    for (int attempt = 0; attempt < 20 && !gConnected; attempt++) {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s < 0) return;
        struct sockaddr_in addr = {0};
        addr.sin_family = AF_INET;
        addr.sin_port = htons((uint16_t)port);
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr);
        if (connect(s, (struct sockaddr *)&addr, sizeof(addr)) == 0) { gSock = s; gConnected = YES; return; }
        close(s);
        usleep(100000);   // 100ms; Jaca binds the listener before launching us
    }
}

static void sendFrame(NSDictionary *obj) {
    dispatch_async(gQueue, ^{
        connectOnce();
        if (!gConnected) return;
        NSError *err = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&err];
        if (!json) return;
        NSMutableData *frame = [json mutableCopy];
        [frame appendBytes:"\n" length:1];
        const uint8_t *bytes = frame.bytes; size_t left = frame.length;
        while (left > 0) {
            ssize_t n = send(gSock, bytes, left, 0);
            if (n <= 0) { close(gSock); gSock = -1; gConnected = NO; return; }
            bytes += n; left -= (size_t)n;
        }
    });
}

// Body → JSON string. JSON strings can't hold invalid UTF-8, so non-text bodies
// (images, protobuf) are reported as a short placeholder rather than corrupting the frame.
static NSString *bodyString(NSData *data) {
    if (data.length == 0) return @"";
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) return s;
    return [NSString stringWithFormat:@"<%lu bytes binary>", (unsigned long)data.length];
}

static NSDictionary *headerDict(NSDictionary *h) { return h ?: @{}; }

#pragma mark - NSURLProtocol interceptor

static NSString *const kHandled = @"JacaHandled";

@interface JacaURLProtocol : NSURLProtocol <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableData *respData;
@property (nonatomic, strong) NSURLResponse *resp;
@property (nonatomic, strong) NSData *reqBody;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) NSTimeInterval responseAt;
@end

@implementation JacaURLProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)r {
    if ([NSURLProtocol propertyForKey:kHandled inRequest:r]) return NO;
    NSString *s = r.URL.scheme.lowercaseString;
    return [s isEqualToString:@"http"] || [s isEqualToString:@"https"];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kHandled inRequest:req];

    // Capture the request body. URLSession uploads use HTTPBodyStream, not HTTPBody;
    // read it, then re-supply it as HTTPBody so the replay still sends it.
    self.reqBody = req.HTTPBody;
    if (!self.reqBody && req.HTTPBodyStream) {
        NSInputStream *in = req.HTTPBodyStream;
        [in open];
        NSMutableData *buf = [NSMutableData data];
        uint8_t tmp[16384];
        while (in.hasBytesAvailable) {
            NSInteger n = [in read:tmp maxLength:sizeof(tmp)];
            if (n <= 0) break;
            [buf appendBytes:tmp length:(NSUInteger)n];
        }
        [in close];
        self.reqBody = buf;
        req.HTTPBodyStream = nil;
        req.HTTPBody = buf;
    }

    self.startedAt = [[NSDate date] timeIntervalSince1970];
    self.respData = [NSMutableData data];
    self.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
                                                 delegate:self delegateQueue:nil];
    self.task = [self.session dataTaskWithRequest:req];
    [self.task resume];
}

- (void)stopLoading { [self.task cancel]; }

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t
 didReceiveResponse:(NSURLResponse *)resp completionHandler:(void (^)(NSURLSessionResponseDisposition))ch {
    self.resp = resp;
    self.responseAt = [[NSDate date] timeIntervalSince1970];
    [self.client URLProtocol:self didReceiveResponse:resp cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    ch(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d {
    [self.respData appendData:d];
    [self.client URLProtocol:self didLoadData:d];
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    NSURLRequest *orig = self.request;
    NSHTTPURLResponse *http = [self.resp isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)self.resp : nil;
    NSTimeInterval finished = [[NSDate date] timeIntervalSince1970];
    NSMutableDictionary *frame = [@{
        @"type": @"txn",
        @"method": orig.HTTPMethod ?: @"GET",
        @"url": orig.URL.absoluteString ?: @"",
        @"startedAt": @(self.startedAt),
        @"finishedAt": @(finished),
        @"requestHeaders": headerDict(orig.allHTTPHeaderFields),
        @"requestBody": bodyString(self.reqBody),
        @"requestSize": @(self.reqBody.length),
        @"responseBody": bodyString(self.respData),
        @"responseSize": @(self.respData.length),
    } mutableCopy];
    if (self.responseAt > 0) frame[@"responseAt"] = @(self.responseAt);
    if (http) { frame[@"status"] = @(http.statusCode); frame[@"responseHeaders"] = headerDict(http.allHeaderFields); }
    if (error) frame[@"error"] = error.localizedDescription ?: @"error";
    sendFrame(frame);

    if (error) { [self.client URLProtocol:self didFailWithError:error]; }
    else { [self.client URLProtocolDidFinishLoading:self]; }
}
@end

#pragma mark - Inject our protocol into every URLSession configuration

static NSURLSessionConfiguration *(*orig_def)(id, SEL);
static NSURLSessionConfiguration *(*orig_eph)(id, SEL);
static void addProto(NSURLSessionConfiguration *c) {
    NSMutableArray *p = [c.protocolClasses mutableCopy] ?: [NSMutableArray array];
    [p insertObject:JacaURLProtocol.class atIndex:0];
    c.protocolClasses = p;
}
static NSURLSessionConfiguration *my_def(id s, SEL c) { NSURLSessionConfiguration *x = orig_def(s, c); addProto(x); return x; }
static NSURLSessionConfiguration *my_eph(id s, SEL c) { NSURLSessionConfiguration *x = orig_eph(s, c); addProto(x); return x; }

__attribute__((constructor))
static void jaca_net_init(void) {
    gQueue = dispatch_queue_create("dev.srsouza.Jaca.netagent", DISPATCH_QUEUE_SERIAL);
    dispatch_async(gQueue, ^{ connectOnce(); });   // connect off the app's launch path

    [NSURLProtocol registerClass:JacaURLProtocol.class];
    Method d = class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration));
    Method e = class_getClassMethod(NSURLSessionConfiguration.class, @selector(ephemeralSessionConfiguration));
    orig_def = (void *)method_getImplementation(d); method_setImplementation(d, (IMP)my_def);
    orig_eph = (void *)method_getImplementation(e); method_setImplementation(e, (IMP)my_eph);
}
