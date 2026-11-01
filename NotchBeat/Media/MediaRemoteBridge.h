#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
/// Runtime-only access: no private framework is linked into the app.
@interface NBMediaRemoteBridge : NSObject
@property(nonatomic, readonly) BOOL available;
- (void)read:(void (^)(NSDictionary<NSString *, id> * _Nullable result))completion;
- (BOOL)sendCommand:(NSInteger)command;
@end
NS_ASSUME_NONNULL_END
