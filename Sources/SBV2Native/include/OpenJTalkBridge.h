#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface StyleBertVits2OpenJTalkBridge : NSObject

+ (void * _Nullable)initializeWithDicPath:(NSString *)dicPath NS_SWIFT_NAME(initialize(dicPath:));
+ (NSArray<NSDictionary<NSString *, id> *> *)runFrontend:(void *)handle
                                                    text:(NSString *)text NS_SWIFT_NAME(runFrontend(_:text:));
+ (NSArray<NSString *> *)makeLabel:(void *)handle
                          features:(NSArray<NSDictionary<NSString *, id> *> *)features NS_SWIFT_NAME(makeLabel(_:features:));
+ (void)releaseHandle:(void *)handle NS_SWIFT_NAME(releaseHandle(_:));

@end

NS_ASSUME_NONNULL_END
