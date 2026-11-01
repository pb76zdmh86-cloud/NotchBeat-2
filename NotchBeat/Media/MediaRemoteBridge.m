#import "MediaRemoteBridge.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>

typedef void (*NBGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*NBGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*NBGetPlaying)(dispatch_queue_t, void (^)(Boolean));
typedef void (*NBRegister)(dispatch_queue_t);
typedef Boolean (*NBSendCommand)(int, CFDictionaryRef);

@implementation NBMediaRemoteBridge {
    void *_handle;
    NBGetInfo _info;
    NBGetPID _pid;
    NBGetPlaying _playing;
    NBSendCommand _command;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY | RTLD_LOCAL);
        if (_handle) {
            _info = (NBGetInfo)dlsym(_handle, "MRMediaRemoteGetNowPlayingInfo");
            _pid = (NBGetPID)dlsym(_handle, "MRMediaRemoteGetNowPlayingApplicationPID");
            _playing = (NBGetPlaying)dlsym(_handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
            _command = (NBSendCommand)dlsym(_handle, "MRMediaRemoteSendCommand");
            NBRegister reg = (NBRegister)dlsym(_handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
            if (reg) reg(dispatch_get_main_queue());
        }
    }
    return self;
}

- (BOOL)available { return _info != NULL; }

- (void)read:(void (^)(NSDictionary<NSString *,id> * _Nullable))completion {
    NSAssert([NSThread isMainThread], @"MediaRemote snapshots are serialized on the main queue");
    if (!_info) { completion(nil); return; }
    __block NSDictionary *info = nil;
    __block NSNumber *playing = nil;
    __block int pid = 0;
    __block BOOL completed = NO;
    __block NSInteger remaining = 1 + (_pid ? 1 : 0) + (_playing ? 1 : 0);

    void (^finish)(BOOL) = ^(BOOL force) {
        if (completed || (!force && remaining > 0)) return;
        completed = YES;
        if (!info || ![info[@"kMRMediaRemoteNowPlayingInfoTitle"] isKindOfClass:NSString.class]) {
            completion(nil); return;
        }
        NSMutableDictionary *result = [info mutableCopy];
        if (playing) result[@"NBIsPlaying"] = playing;
        NSRunningApplication *app = pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid] : nil;
        if (app.bundleIdentifier) result[@"NBBundleID"] = app.bundleIdentifier;
        completion(result);
    };

    // Some OS versions never call the callback when access is denied.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(YES); });
    _info(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
        if (completed) return;
        info = raw ? [(__bridge NSDictionary *)raw copy] : nil;
        remaining--; finish(NO);
    });
    if (_pid) _pid(dispatch_get_main_queue(), ^(int value) {
        if (completed) return;
        pid = value; remaining--; finish(NO);
    });
    if (_playing) _playing(dispatch_get_main_queue(), ^(Boolean value) {
        if (completed) return;
        playing = @(value); remaining--; finish(NO);
    });
}

- (BOOL)sendCommand:(NSInteger)command {
    // 2 toggle, 4 next, 5 previous: private ABI, keep isolated here.
    if (!_command || (command != 2 && command != 4 && command != 5)) return NO;
    return _command((int)command, NULL);
}
// Intentionally do not dlclose a framework that may still own asynchronous callbacks.
@end
