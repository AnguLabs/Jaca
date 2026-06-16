#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// One structured os_log event from a physical device — the subset of
/// `OSActivityLogMessageEvent` we surface. Bridged to Swift.
@interface JacaOSLogEvent : NSObject
/// messageType: 0=Default, 1=Info, 2=Debug, 16=Error, 17=Fault.
@property (nonatomic, readonly) unsigned char level;
@property (nonatomic, readonly) int processID;
@property (nonatomic, readonly) double timestamp;            // epoch seconds
@property (nonatomic, copy, readonly, nullable) NSString *process;
@property (nonatomic, copy, readonly, nullable) NSString *sender;
@property (nonatomic, copy, readonly, nullable) NSString *subsystem;
@property (nonatomic, copy, readonly, nullable) NSString *category;
@property (nonatomic, copy, readonly, nullable) NSString *message;
@end

/// Streams structured os_log from a physical iOS device via Apple's PRIVATE
/// `LoggingSupport.framework` (`OSActivityStream`) + `MobileDevice.framework` — the
/// same engine Xcode's console and Console.app use. ALL private-API access is
/// isolated in this class; every entry point fails soft (nil / NO) so Swift can
/// fall back to a supported source. Events are delivered on a background queue.
///
/// If a macOS/Xcode upgrade breaks this, see the `investigate-loggingsupport` skill.
@interface JacaOSLogStream : NSObject

/// YES if the private frameworks + classes load on this macOS/Xcode build.
+ (BOOL)isAvailable;

/// Returns nil if the device handle or private classes can't be obtained (caller
/// must fall back). `onEvent` is called on a background queue for each event.
- (nullable instancetype)initWithUDID:(NSString *)udid
                              onEvent:(void (^)(JacaOSLogEvent *event))onEvent;

/// Begins streaming on a dedicated runloop thread. NO if it couldn't start.
- (BOOL)start;
/// Stops streaming and tears down. Idempotent.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
