#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Native Core ML BERT and phoneme feature expansion. No external inference runtime.
@interface StyleBertVits2CoreMLBert : NSObject

+ (void * _Nullable)createSessionWithBertPath:(NSString *)bertPath NS_SWIFT_NAME(createSession(withBertPath:));

/// Load both BERT blocks while independent model preparation runs on the caller's thread.
/// Returns only after both preparations finish, so the session can then be used or released.
+ (BOOL)prepareSession:(void *)session
        concurrentWork:(void (NS_NOESCAPE ^)(void))concurrentWork NS_SWIFT_NAME(prepareSession(_:concurrentWork:));

+ (NSData *)runBertInferenceDataWithSession:(void *)session
                               tokenIdsData:(NSData *)tokenIdsData
                          attentionMaskData:(NSData *)attentionMaskData NS_SWIFT_NAME(runBertInferenceData(withSession:tokenIdsData:attentionMaskData:));

+ (NSData *)expandBertFeaturesData:(NSData *)bertFeaturesData
                       word2phData:(NSData *)word2phData
                          tokenLen:(NSInteger)tokenLen
                        featureDim:(NSInteger)featureDim NS_SWIFT_NAME(expandBertFeaturesData(_:word2phData:tokenLen:featureDim:));

+ (void)releaseSession:(void *)session NS_SWIFT_NAME(releaseSession(_:));
+ (NSString *)lastError NS_SWIFT_NAME(lastError());

@end
NS_ASSUME_NONNULL_END
