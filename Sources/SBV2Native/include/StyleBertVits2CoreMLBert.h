#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Native Core ML BERT and phoneme feature expansion. No external inference runtime.
@interface StyleBertVits2CoreMLBert : NSObject

+ (void * _Nullable)createSessionWithBertPath:(NSString *)bertPath NS_SWIFT_NAME(createSession(withBertPath:));

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
