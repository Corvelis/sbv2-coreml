#import "StyleBertVits2CoreMLBert.h"
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <os/log.h>
#import <mach/mach.h>
#include <vector>
#include <string>
#include <memory>
#include <algorithm>
#include <limits>
#include <cstring>

#if DEBUG
#define EDGE_TTS_NSLOG(...) NSLog(__VA_ARGS__)
#define EDGE_TTS_FPRINTF(...) fprintf(stderr, __VA_ARGS__)
#else
#define EDGE_TTS_NSLOG(...)
#define EDGE_TTS_FPRINTF(...)
#endif

namespace {

struct BertCoreMLBlock {
    std::string blockName;
    std::vector<std::string> semanticInputNames;
    std::vector<std::string> semanticOutputNames;
    std::vector<std::string> coreMLInputNames;
    std::vector<std::string> coreMLOutputNames;
    std::string packagePath;
    int64_t minSequenceLength = 0;
    int64_t maxSequenceLength = 0;
    std::vector<int64_t> sequenceLengthCandidates;
    void *modelHandle = nullptr;
};

struct StyleBertVits2Session {
    std::vector<BertCoreMLBlock> bertCoreMLBlocks;
    ~StyleBertVits2Session() {
        for (auto &block : bertCoreMLBlocks) {
            if (block.modelHandle != nullptr) CFBridgingRelease(block.modelHandle);
        }
    }
};
static std::string g_last_error;

static void logPublicEdgeTtsMessage(const std::string &message) {
#if DEBUG
    if (message.empty()) {
        return;
    }
    os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_ERROR, "%{public}s", message.c_str());
#endif
}
static void logMemoryFootprint(const char *label) {
    task_vm_info_data_t vmInfo;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self_,
                                 TASK_VM_INFO,
                                 reinterpret_cast<task_info_t>(&vmInfo),
                                 &count);
    if (kr != KERN_SUCCESS) {
        EDGE_TTS_FPRINTF("[SBV2CoreML] mem:%s unavailable kr=%d\n", label ?: "(null)", kr);
        return;
    }
    const double physMb = (double)vmInfo.phys_footprint / (1024.0 * 1024.0);
    const double residentMb = (double)vmInfo.resident_size / (1024.0 * 1024.0);
    const double virtualMb = (double)vmInfo.virtual_size / (1024.0 * 1024.0);
    EDGE_TTS_FPRINTF(
            "[SBV2CoreML] mem:%s phys=%.1fMB resident=%.1fMB virtual=%.1fMB\n",
            label ?: "(null)",
            physMb,
            residentMb,
            virtualMb);
}

static std::vector<int64_t> toInt64VectorFromData(NSData *data) {
    std::vector<int64_t> out;
    if (data == nil) {
        return out;
    }
    const size_t count = data.length / sizeof(int64_t);
    out.resize(count);
    if (count > 0) {
        memcpy(out.data(), data.bytes, count * sizeof(int64_t));
    }
    return out;
}

static std::vector<int64_t> toInt64VectorFromInt32Data(NSData *data) {
    std::vector<int64_t> out;
    if (data == nil) {
        return out;
    }
    const size_t count = data.length / sizeof(int32_t);
    out.resize(count);
    const int32_t *src = static_cast<const int32_t *>(data.bytes);
    for (size_t i = 0; i < count; i++) {
        out[i] = src[i];
    }
    return out;
}

static std::vector<float> toFloatVectorFromData(NSData *data) {
    std::vector<float> out;
    if (data == nil) {
        return out;
    }
    const size_t count = data.length / sizeof(float);
    out.resize(count);
    if (count > 0) {
        memcpy(out.data(), data.bytes, count * sizeof(float));
    }
    return out;
}

static NSData *dataFromFloatVector(const std::vector<float> &data) {
    if (data.empty()) {
        return [NSData data];
    }
    return [NSData dataWithBytes:data.data() length:data.size() * sizeof(float)];
}

static std::string describeNSError(NSError *error) {
    if (error == nil) {
        return "unknown NSError";
    }
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (error.localizedDescription.length > 0) {
        [parts addObject:error.localizedDescription];
    }
    [parts addObject:[NSString stringWithFormat:@"domain=%@", error.domain ?: @"(nil)"]];
    [parts addObject:[NSString stringWithFormat:@"code=%ld", (long)error.code]];
    if (error.localizedFailureReason.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"reason=%@", error.localizedFailureReason]];
    }
    if (error.localizedRecoverySuggestion.length > 0) {
        [parts addObject:[NSString stringWithFormat:@"suggestion=%@", error.localizedRecoverySuggestion]];
    }
    NSError *underlying = error.userInfo[NSUnderlyingErrorKey];
    if ([underlying isKindOfClass:[NSError class]]) {
        [parts addObject:[NSString stringWithFormat:@"underlying={%@}", [NSString stringWithUTF8String:describeNSError(underlying).c_str()]]];
    }
    return std::string([[parts componentsJoinedByString:@" | "] UTF8String]);
}

static NSString *compiledCoreMLCachePathForPackage(NSString *packagePath) {
    NSString *parentDir = [packagePath stringByDeletingLastPathComponent];
    NSString *packageName = [[packagePath lastPathComponent] stringByDeletingPathExtension];
    return [parentDir stringByAppendingPathComponent:[packageName stringByAppendingPathExtension:@"mlmodelc"]];
}

static NSDate *latestModificationDateForPath(NSString *path) {
    if (path == nil) {
        return nil;
    }
    NSFileManager *fileManager = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fileManager fileExistsAtPath:path isDirectory:&isDirectory]) {
        return nil;
    }

    NSDate *latest = nil;
    NSDictionary<NSFileAttributeKey, id> *attrs = [fileManager attributesOfItemAtPath:path error:nil];
    NSDate *selfModified = attrs[NSFileModificationDate];
    if ([selfModified isKindOfClass:[NSDate class]]) {
        latest = selfModified;
    }

    if (!isDirectory) {
        return latest;
    }

    NSDirectoryEnumerator<NSString *> *enumerator = [fileManager enumeratorAtPath:path];
    for (NSString *relative in enumerator) {
        NSString *childPath = [path stringByAppendingPathComponent:relative];
        NSDictionary<NSFileAttributeKey, id> *childAttrs = [fileManager attributesOfItemAtPath:childPath error:nil];
        NSDate *childModified = childAttrs[NSFileModificationDate];
        if ([childModified isKindOfClass:[NSDate class]] &&
            (latest == nil || [latest compare:childModified] == NSOrderedAscending)) {
            latest = childModified;
        }
    }
    return latest;
}

static bool ensureCompiledCoreMLModelAtPath(NSString *packagePath,
                                            NSString **outCompiledPath,
                                            const char *context) {
    if (packagePath == nil || outCompiledPath == nullptr) {
        g_last_error = std::string(context) + ": invalid CoreML package path";
        return false;
    }
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSString *compiledPath = compiledCoreMLCachePathForPackage(packagePath);
    EDGE_TTS_NSLOG(@"[SBV2CoreML] coreml_cache:check package=%@ compiled=%@",
          packagePath.lastPathComponent,
          compiledPath.lastPathComponent);
    NSDate *packageModified = latestModificationDateForPath(packagePath);
    NSDate *compiledModified = latestModificationDateForPath(compiledPath);
    bool hasUsableCompiledCache =
        [fileManager fileExistsAtPath:compiledPath] &&
        (compiledModified == nil || packageModified == nil || [compiledModified compare:packageModified] != NSOrderedAscending);
    EDGE_TTS_NSLOG(@"[SBV2CoreML] coreml_cache:usable=%d packageExists=%d compiledExists=%d",
          hasUsableCompiledCache ? 1 : 0,
          [fileManager fileExistsAtPath:packagePath] ? 1 : 0,
          [fileManager fileExistsAtPath:compiledPath] ? 1 : 0);
    if (!hasUsableCompiledCache) {
        EDGE_TTS_NSLOG(@"[SBV2CoreML] coreml_cache:compile_begin");
        logMemoryFootprint("coreml_cache_compile_begin");
        NSError *error = nil;
        NSURL *packageURL = [NSURL fileURLWithPath:packagePath];
        NSURL *compiledURL = [MLModel compileModelAtURL:packageURL error:&error];
        if (compiledURL == nil || error != nil) {
            if (compiledURL != nil) [fileManager removeItemAtURL:compiledURL error:nil];
            g_last_error = std::string(context) + ": compile failed: " + describeNSError(error);
            EDGE_TTS_FPRINTF("[SBV2CoreML] %s\n", g_last_error.c_str());
            logPublicEdgeTtsMessage(g_last_error);
            return false;
        }
        EDGE_TTS_NSLOG(@"[SBV2CoreML] coreml_cache:compile_done");
        logMemoryFootprint("coreml_cache_compile_done");
        if ([fileManager fileExistsAtPath:compiledPath]) {
            if (![fileManager removeItemAtPath:compiledPath error:&error]) {
                [fileManager removeItemAtURL:compiledURL error:nil];
                g_last_error = std::string(context) + ": remove stale compiled cache failed: " + describeNSError(error);
                return false;
            }
        }
        if (![fileManager copyItemAtURL:compiledURL toURL:[NSURL fileURLWithPath:compiledPath] error:&error]) {
            [fileManager removeItemAtURL:compiledURL error:nil];
            [fileManager removeItemAtPath:compiledPath error:nil];
            g_last_error = std::string(context) + ": persist compiled cache failed: " + describeNSError(error);
            return false;
        }
        [fileManager removeItemAtURL:compiledURL error:nil];
        EDGE_TTS_NSLOG(@"[SBV2CoreML] Compiled CoreML model cache created: %@", compiledPath.lastPathComponent);
    }
    *outCompiledPath = compiledPath;
    EDGE_TTS_NSLOG(@"[SBV2CoreML] coreml_cache:ready %@", compiledPath.lastPathComponent);
    return true;
}

static bool createCoreMLModelForPackage(NSString *packagePath, MLComputeUnits computeUnits, void **outHandle, const char *context) {
    NSString *compiledPath = nil;
    EDGE_TTS_NSLOG(@"[SBV2CoreML] coreml_model:create_begin package=%@ units=%ld",
          packagePath.lastPathComponent,
          (long)computeUnits);
    logMemoryFootprint("coreml_model_create_begin");
    if (!ensureCompiledCoreMLModelAtPath(packagePath, &compiledPath, context)) {
        return false;
    }
    NSError *error = nil;
    MLModelConfiguration *config = [[MLModelConfiguration alloc] init];
    config.computeUnits = computeUnits;
    EDGE_TTS_NSLOG(@"[SBV2CoreML] coreml_model:before_load compiled=%@",
          compiledPath.lastPathComponent);
    logMemoryFootprint("coreml_model_before_load");
    MLModel *model = [MLModel modelWithContentsOfURL:[NSURL fileURLWithPath:compiledPath] configuration:config error:&error];
    EDGE_TTS_NSLOG(@"[SBV2CoreML] coreml_model:after_load");
    logMemoryFootprint("coreml_model_after_load");
    if (model == nil || error != nil) {
        g_last_error = std::string(context) + ": load failed: " + describeNSError(error);
        return false;
    }
    *outHandle = (__bridge_retained void *)model;
    EDGE_TTS_NSLOG(@"[SBV2CoreML] coreml_model:create_done");
    return true;
}

static NSString *coreMLBertBlocksManifestPathForBertPath(NSString *bertPath) {
    BOOL isDirectory = NO;
    [[NSFileManager defaultManager] fileExistsAtPath:bertPath isDirectory:&isDirectory];
    // Accept the BERT directory or a file inside it for legacy path callers.
    NSString *bertDir = isDirectory ? bertPath : [bertPath stringByDeletingLastPathComponent];
    return [[bertDir stringByAppendingPathComponent:@"coreml_blocks"]
        stringByAppendingPathComponent:@"coreml_bert_blocks_manifest.json"];
}

static bool loadCoreMLBertBlocksManifest(StyleBertVits2Session *session, NSString *bertPath) {
    NSString *manifestPath = coreMLBertBlocksManifestPathForBertPath(bertPath);
    if (![[NSFileManager defaultManager] fileExistsAtPath:manifestPath]) {
        return false;
    }
    NSData *data = [NSData dataWithContentsOfFile:manifestPath];
    if (data == nil) {
        return false;
    }
    NSError *error = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![json isKindOfClass:[NSDictionary class]]) {
        EDGE_TTS_NSLOG(@"[SBV2CoreML] BERT CoreML blocks manifest parse failed: %@", manifestPath);
        return false;
    }
    NSArray *blocks = json[@"blocks"];
    if (![blocks isKindOfClass:[NSArray class]]) {
        return false;
    }
    NSString *manifestDir = [manifestPath stringByDeletingLastPathComponent];
    size_t loadedCount = 0;
    for (id item in blocks) {
        if (![item isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSDictionary *entry = (NSDictionary *)item;
        NSString *blockName = entry[@"block"];
        NSString *mlpackagePath = entry[@"mlpackage"];
        NSArray *coreMLInputNames = entry[@"coreml_input_names"];
        NSArray *coreMLOutputNames = entry[@"coreml_output_names"];
        NSArray *semanticInputNames = entry[@"semantic_input_names"];
        NSArray *semanticOutputNames = entry[@"semantic_output_names"];
        NSDictionary *sequenceLengthRange = entry[@"sequence_length_range"];
        NSArray *sequenceLengthCandidates = entry[@"sequence_length_candidates"];
        if (![blockName isKindOfClass:[NSString class]] ||
            ![mlpackagePath isKindOfClass:[NSString class]] ||
            ![coreMLInputNames isKindOfClass:[NSArray class]] ||
            ![coreMLOutputNames isKindOfClass:[NSArray class]]) {
            continue;
        }
        NSString *packagePath = [manifestDir stringByAppendingPathComponent:[mlpackagePath lastPathComponent]];
        NSString *compiledPath = compiledCoreMLCachePathForPackage(packagePath);
        if (![[NSFileManager defaultManager] fileExistsAtPath:packagePath] &&
            ![[NSFileManager defaultManager] fileExistsAtPath:compiledPath]) {
            EDGE_TTS_NSLOG(@"[SBV2CoreML] BERT CoreML block package missing on device: %@ / %@",
                  packagePath,
                  compiledPath);
            continue;
        }
        BertCoreMLBlock block;
        block.blockName = std::string(blockName.UTF8String ?: "");
        block.packagePath = std::string(packagePath.UTF8String ?: "");
        if ([semanticInputNames isKindOfClass:[NSArray class]]) {
            for (id value in semanticInputNames) {
                if ([value isKindOfClass:[NSString class]]) {
                    block.semanticInputNames.push_back(std::string([(NSString *)value UTF8String] ?: ""));
                }
            }
        }
        if ([semanticOutputNames isKindOfClass:[NSArray class]]) {
            for (id value in semanticOutputNames) {
                if ([value isKindOfClass:[NSString class]]) {
                    block.semanticOutputNames.push_back(std::string([(NSString *)value UTF8String] ?: ""));
                }
            }
        }
        for (id value in coreMLInputNames) {
            if ([value isKindOfClass:[NSString class]]) {
                block.coreMLInputNames.push_back(std::string([(NSString *)value UTF8String] ?: ""));
            }
        }
        for (id value in coreMLOutputNames) {
            if ([value isKindOfClass:[NSString class]]) {
                block.coreMLOutputNames.push_back(std::string([(NSString *)value UTF8String] ?: ""));
            }
        }
        if ([sequenceLengthRange isKindOfClass:[NSDictionary class]]) {
            NSNumber *minLength = sequenceLengthRange[@"min"];
            NSNumber *maxLength = sequenceLengthRange[@"max"];
            if ([minLength isKindOfClass:[NSNumber class]]) {
                block.minSequenceLength = minLength.longLongValue;
            }
            if ([maxLength isKindOfClass:[NSNumber class]]) {
                block.maxSequenceLength = maxLength.longLongValue;
            }
        }
        if ([sequenceLengthCandidates isKindOfClass:[NSArray class]]) {
            for (id value in sequenceLengthCandidates) {
                if ([value isKindOfClass:[NSNumber class]] && [value longLongValue] > 0) {
                    block.sequenceLengthCandidates.push_back([value longLongValue]);
                }
            }
            std::sort(block.sequenceLengthCandidates.begin(), block.sequenceLengthCandidates.end());
        }
        session->bertCoreMLBlocks.push_back(std::move(block));
        loadedCount++;
    }
    if (loadedCount > 0) {
        EDGE_TTS_NSLOG(@"[SBV2CoreML] Loaded %zu BERT CoreML block entries from %@", loadedCount, manifestPath.lastPathComponent);
        return true;
    }
    return false;
}

static BertCoreMLBlock *findBertCoreMLBlock(StyleBertVits2Session *session, const std::string &blockName) {
    if (session == nullptr) {
        return nullptr;
    }
    for (BertCoreMLBlock &block : session->bertCoreMLBlocks) {
        if (block.blockName == blockName) {
            return &block;
        }
    }
    return nullptr;
}

static bool writeFloatTensorToMultiArray(MLMultiArray *array, const float *src, size_t count) {
    if (array == nil || src == nullptr) {
        return false;
    }
    if (array.dataType == MLMultiArrayDataTypeFloat32) {
        float *dst = static_cast<float *>(array.dataPointer);
        if (dst == nullptr) {
            return false;
        }
        memcpy(dst, src, sizeof(float) * count);
        return true;
    }
    if (array.dataType == MLMultiArrayDataTypeFloat16) {
        __fp16 *dst = static_cast<__fp16 *>(array.dataPointer);
        if (dst == nullptr) {
            return false;
        }
        for (size_t i = 0; i < count; i++) {
            dst[i] = (__fp16)src[i];
        }
        return true;
    }
    return false;
}

static bool readMultiArrayToFloatBuffer(MLMultiArray *array, float *dst, size_t count) {
    if (array == nil || dst == nullptr) {
        return false;
    }
    if (array.dataType == MLMultiArrayDataTypeFloat32) {
        float *src = static_cast<float *>(array.dataPointer);
        if (src == nullptr) {
            return false;
        }
        memcpy(dst, src, sizeof(float) * count);
        return true;
    }
    if (array.dataType == MLMultiArrayDataTypeFloat16) {
        __fp16 *src = static_cast<__fp16 *>(array.dataPointer);
        if (src == nullptr) {
            return false;
        }
        for (size_t i = 0; i < count; i++) {
            dst[i] = (float)src[i];
        }
        return true;
    }
    return false;
}

static bool writeInt64VectorToMultiArray(MLMultiArray *array, const std::vector<int64_t> &src) {
    if (array == nil || array.count != src.size()) {
        return false;
    }
    if (array.dataType == MLMultiArrayDataTypeFloat16) {
        __fp16 *dst = static_cast<__fp16 *>(array.dataPointer);
        if (dst == nullptr) {
            return false;
        }
        for (size_t i = 0; i < src.size(); i++) {
            dst[i] = static_cast<__fp16>(src[i]);
        }
        return true;
    }
    if (array.dataType == MLMultiArrayDataTypeInt32) {
        int32_t *dst = static_cast<int32_t *>(array.dataPointer);
        if (dst == nullptr) {
            return false;
        }
        for (size_t i = 0; i < src.size(); i++) {
            dst[i] = static_cast<int32_t>(src[i]);
        }
        return true;
    }
    if (array.dataType == MLMultiArrayDataTypeDouble) {
        double *dst = static_cast<double *>(array.dataPointer);
        if (dst == nullptr) {
            return false;
        }
        for (size_t i = 0; i < src.size(); i++) {
            dst[i] = static_cast<double>(src[i]);
        }
        return true;
    }
    if (array.dataType == MLMultiArrayDataTypeFloat32) {
        float *dst = static_cast<float *>(array.dataPointer);
        if (dst == nullptr) {
            return false;
        }
        for (size_t i = 0; i < src.size(); i++) {
            dst[i] = static_cast<float>(src[i]);
        }
        return true;
    }
    return false;
}

static NSData *runBertCoreMLBlockEmbeddingsData(BertCoreMLBlock *block,
                                                const std::vector<int64_t> &tokens,
                                                const std::vector<int64_t> &masks,
                                                NSData **secondaryOutputData = nullptr) {
    if (secondaryOutputData != nullptr) {
        *secondaryOutputData = nil;
    }
    if (block == nullptr || block->packagePath.empty()) {
        return [NSData data];
    }
    if (tokens.empty() || tokens.size() != masks.size()) {
        g_last_error = "BERT CoreML block embeddings input length mismatch";
        return [NSData data];
    }
    const int64_t sequenceLength = static_cast<int64_t>(tokens.size());
    if ((block->minSequenceLength > 0 && sequenceLength < block->minSequenceLength) ||
        (block->maxSequenceLength > 0 && sequenceLength > block->maxSequenceLength)) {
        g_last_error = "BERT CoreML block embeddings sequence length out of supported range";
        return [NSData data];
    }
    if (block->coreMLInputNames.size() < 2 || block->coreMLOutputNames.empty() ||
        (secondaryOutputData != nullptr && block->coreMLOutputNames.size() < 2)) {
        g_last_error = "BERT CoreML block embeddings manifest missing I/O names";
        return [NSData data];
    }
    if (block->modelHandle == nullptr) {
        NSString *packagePath = [NSString stringWithUTF8String:block->packagePath.c_str()];
        void *modelHandle = nullptr;
        if (!createCoreMLModelForPackage(packagePath, MLComputeUnitsAll, &modelHandle, "Load BERT CoreML block embeddings")) {
            return [NSData data];
        }
        block->modelHandle = modelHandle;
    }

    MLModel *model = (__bridge MLModel *)block->modelHandle;
    NSString *inputIdsName = [NSString stringWithUTF8String:block->coreMLInputNames[0].c_str()];
    NSString *attentionMaskName = [NSString stringWithUTF8String:block->coreMLInputNames[1].c_str()];
    NSString *outputName = [NSString stringWithUTF8String:block->coreMLOutputNames[0].c_str()];

    MLFeatureDescription *inputIdsDescription = model.modelDescription.inputDescriptionsByName[inputIdsName];
    MLFeatureDescription *attentionMaskDescription = model.modelDescription.inputDescriptionsByName[attentionMaskName];
    if (inputIdsDescription == nil || attentionMaskDescription == nil ||
        inputIdsDescription.multiArrayConstraint == nil || attentionMaskDescription.multiArrayConstraint == nil) {
        g_last_error = "BERT CoreML block embeddings input description missing";
        return [NSData data];
    }

    NSError *error = nil;
    NSArray<NSNumber *> *shape = @[ @1, @(sequenceLength) ];
    MLMultiArray *inputIdsArray =
        [[MLMultiArray alloc] initWithShape:shape
                                   dataType:inputIdsDescription.multiArrayConstraint.dataType
                                      error:&error];
    if (inputIdsArray == nil || error != nil) {
        g_last_error = "BERT CoreML block embeddings input_ids MLMultiArray init failed: " + describeNSError(error);
        return [NSData data];
    }
    error = nil;
    MLMultiArray *attentionMaskArray =
        [[MLMultiArray alloc] initWithShape:shape
                                   dataType:attentionMaskDescription.multiArrayConstraint.dataType
                                      error:&error];
    if (attentionMaskArray == nil || error != nil) {
        g_last_error = "BERT CoreML block embeddings attention_mask MLMultiArray init failed: " + describeNSError(error);
        return [NSData data];
    }
    if (!writeInt64VectorToMultiArray(inputIdsArray, tokens) ||
        !writeInt64VectorToMultiArray(attentionMaskArray, masks)) {
        g_last_error = "BERT CoreML block embeddings unsupported integer input MLMultiArray dtype";
        return [NSData data];
    }

    MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc]
        initWithDictionary:@{
            inputIdsName: inputIdsArray,
            attentionMaskName: attentionMaskArray,
        }
        error:&error];
    if (provider == nil || error != nil) {
        g_last_error = "BERT CoreML block embeddings feature provider init failed: " + describeNSError(error);
        return [NSData data];
    }

    id<MLFeatureProvider> prediction = [model predictionFromFeatures:provider error:&error];
    if (prediction == nil || error != nil) {
        g_last_error = "BERT CoreML block embeddings prediction failed: " + describeNSError(error);
        return [NSData data];
    }

    MLFeatureValue *feature = [prediction featureValueForName:outputName];
    if (feature == nil || feature.type != MLFeatureTypeMultiArray || feature.multiArrayValue == nil) {
        g_last_error = "BERT CoreML block embeddings output feature missing";
        return [NSData data];
    }
    MLMultiArray *outputArray = feature.multiArrayValue;
    size_t outputCount = 1;
    for (NSNumber *dim in outputArray.shape) {
        outputCount *= dim.unsignedLongLongValue;
    }
    std::vector<float> output(outputCount);
    if (!readMultiArrayToFloatBuffer(outputArray, output.data(), outputCount)) {
        g_last_error = "BERT CoreML block embeddings unsupported output MLMultiArray dtype";
        return [NSData data];
    }
    if (secondaryOutputData != nullptr) {
        NSString *secondaryName = [NSString stringWithUTF8String:block->coreMLOutputNames[1].c_str()];
        MLFeatureValue *secondaryFeature = [prediction featureValueForName:secondaryName];
        if (secondaryFeature == nil || secondaryFeature.type != MLFeatureTypeMultiArray ||
            secondaryFeature.multiArrayValue == nil) {
            g_last_error = "BERT CoreML block secondary output missing";
            return [NSData data];
        }
        MLMultiArray *secondaryArray = secondaryFeature.multiArrayValue;
        size_t secondaryCount = 1;
        for (NSNumber *dim in secondaryArray.shape) {
            secondaryCount *= dim.unsignedLongLongValue;
        }
        std::vector<float> secondary(secondaryCount);
        if (!readMultiArrayToFloatBuffer(secondaryArray, secondary.data(), secondaryCount)) {
            g_last_error = "BERT CoreML block secondary output dtype unsupported";
            return [NSData data];
        }
        *secondaryOutputData = dataFromFloatVector(secondary);
    }
    return dataFromFloatVector(output);
}

static NSData *runBertCoreMLBlockTwoFloatInputsAndMaskData(BertCoreMLBlock *block,
                                                           NSData *firstInputData,
                                                           NSData *secondInputData,
                                                           const std::vector<int64_t> &masks,
                                                           const char *context) {
    if (block == nullptr || block->packagePath.empty() || firstInputData == nil || secondInputData == nil) {
        return [NSData data];
    }
    const size_t sequenceLength = masks.size();
    if (sequenceLength == 0 || firstInputData.length == 0 || secondInputData.length == 0) {
        g_last_error = std::string(context) + ": input data missing";
        return [NSData data];
    }
    const size_t firstElementCount = firstInputData.length / sizeof(float);
    const size_t secondElementCount = secondInputData.length / sizeof(float);
    if (firstElementCount % sequenceLength != 0 || secondElementCount % sequenceLength != 0) {
        g_last_error = std::string(context) + ": input shape mismatch";
        return [NSData data];
    }
    const size_t firstHiddenSize = firstElementCount / sequenceLength;
    const size_t secondHiddenSize = secondElementCount / sequenceLength;
    if (block->coreMLInputNames.size() < 3 || block->coreMLOutputNames.empty()) {
        g_last_error = std::string(context) + ": manifest missing I/O names";
        return [NSData data];
    }
    if (block->modelHandle == nullptr) {
        NSString *packagePath = [NSString stringWithUTF8String:block->packagePath.c_str()];
        void *modelHandle = nullptr;
        if (!createCoreMLModelForPackage(packagePath, MLComputeUnitsAll, &modelHandle, context)) {
            return [NSData data];
        }
        block->modelHandle = modelHandle;
    }

    MLModel *model = (__bridge MLModel *)block->modelHandle;
    NSString *firstName = [NSString stringWithUTF8String:block->coreMLInputNames[0].c_str()];
    NSString *secondName = [NSString stringWithUTF8String:block->coreMLInputNames[1].c_str()];
    NSString *maskName = [NSString stringWithUTF8String:block->coreMLInputNames[2].c_str()];
    NSString *outputName = [NSString stringWithUTF8String:block->coreMLOutputNames[0].c_str()];
    MLFeatureDescription *firstDescription = model.modelDescription.inputDescriptionsByName[firstName];
    MLFeatureDescription *secondDescription = model.modelDescription.inputDescriptionsByName[secondName];
    MLFeatureDescription *maskDescription = model.modelDescription.inputDescriptionsByName[maskName];
    if (firstDescription == nil || secondDescription == nil || maskDescription == nil ||
        firstDescription.multiArrayConstraint == nil || secondDescription.multiArrayConstraint == nil ||
        maskDescription.multiArrayConstraint == nil) {
        g_last_error = std::string(context) + ": input description missing";
        return [NSData data];
    }

    NSError *error = nil;
    NSArray<NSNumber *> *firstShape = @[ @1, @(sequenceLength), @(firstHiddenSize) ];
    MLMultiArray *firstArray = [[MLMultiArray alloc] initWithShape:firstShape
                                                          dataType:firstDescription.multiArrayConstraint.dataType
                                                             error:&error];
    if (firstArray == nil || error != nil) {
        g_last_error = std::string(context) + ": first MLMultiArray init failed: " + describeNSError(error);
        return [NSData data];
    }
    const float *firstSrc = static_cast<const float *>(firstInputData.bytes);
    if (firstSrc == nullptr || !writeFloatTensorToMultiArray(firstArray, firstSrc, firstElementCount)) {
        g_last_error = std::string(context) + ": unsupported first input MLMultiArray dtype";
        return [NSData data];
    }

    error = nil;
    NSArray<NSNumber *> *secondShape = @[ @1, @(sequenceLength), @(secondHiddenSize) ];
    MLMultiArray *secondArray = [[MLMultiArray alloc] initWithShape:secondShape
                                                           dataType:secondDescription.multiArrayConstraint.dataType
                                                              error:&error];
    if (secondArray == nil || error != nil) {
        g_last_error = std::string(context) + ": second MLMultiArray init failed: " + describeNSError(error);
        return [NSData data];
    }
    const float *secondSrc = static_cast<const float *>(secondInputData.bytes);
    if (secondSrc == nullptr || !writeFloatTensorToMultiArray(secondArray, secondSrc, secondElementCount)) {
        g_last_error = std::string(context) + ": unsupported second input MLMultiArray dtype";
        return [NSData data];
    }

    error = nil;
    NSArray<NSNumber *> *maskShape = @[ @1, @(sequenceLength) ];
    MLMultiArray *maskArray = [[MLMultiArray alloc] initWithShape:maskShape
                                                         dataType:maskDescription.multiArrayConstraint.dataType
                                                            error:&error];
    if (maskArray == nil || error != nil) {
        g_last_error = std::string(context) + ": attention_mask MLMultiArray init failed: " + describeNSError(error);
        return [NSData data];
    }
    if (!writeInt64VectorToMultiArray(maskArray, masks)) {
        g_last_error = std::string(context) + ": unsupported attention_mask MLMultiArray dtype";
        return [NSData data];
    }

    MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc]
        initWithDictionary:@{
            firstName: firstArray,
            secondName: secondArray,
            maskName: maskArray,
        }
        error:&error];
    if (provider == nil || error != nil) {
        g_last_error = std::string(context) + ": feature provider init failed: " + describeNSError(error);
        return [NSData data];
    }
    id<MLFeatureProvider> prediction = [model predictionFromFeatures:provider error:&error];
    if (prediction == nil || error != nil) {
        g_last_error = std::string(context) + ": prediction failed: " + describeNSError(error);
        return [NSData data];
    }
    MLFeatureValue *feature = [prediction featureValueForName:outputName];
    if (feature == nil || feature.type != MLFeatureTypeMultiArray || feature.multiArrayValue == nil) {
        g_last_error = std::string(context) + ": output feature missing";
        return [NSData data];
    }
    MLMultiArray *outputArray = feature.multiArrayValue;
    size_t outputCount = 1;
    for (NSNumber *dim in outputArray.shape) {
        outputCount *= dim.unsignedLongLongValue;
    }
    std::vector<float> output(outputCount);
    if (!readMultiArrayToFloatBuffer(outputArray, output.data(), outputCount)) {
        g_last_error = std::string(context) + ": unsupported output MLMultiArray dtype";
        return [NSData data];
    }
    return dataFromFloatVector(output);
}

} // namespace

@implementation StyleBertVits2CoreMLBert

+ (BOOL)prepareSession:(void *)session concurrentWork:(void (^)(void))concurrentWork {
    g_last_error.clear();
    if (session == nullptr) {
        g_last_error = "Core ML BERT preparation requires a session";
        return NO;
    }
    auto *bertSession = static_cast<StyleBertVits2Session *>(session);
    __block BOOL prepared = NO;
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            prepared = YES;
            for (auto &block : bertSession->bertCoreMLBlocks) {
                if (block.modelHandle != nullptr) continue;
                NSString *path = [NSString stringWithUTF8String:block.packagePath.c_str()];
                if (!createCoreMLModelForPackage(path, MLComputeUnitsAll, &block.modelHandle,
                                                "Prepare BERT Core ML block")) {
                    prepared = NO;
                    break;
                }
            }
        }
    });
    concurrentWork();
    // A failed voice load must also wait before releasing the BERT session.
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return prepared;
}

+ (void *)createSessionWithBertPath:(NSString *)bertPath {
    g_last_error.clear();
    auto session = std::make_unique<StyleBertVits2Session>();
    if (!loadCoreMLBertBlocksManifest(session.get(), bertPath) ||
        findBertCoreMLBlock(session.get(), "prefix.0") == nullptr ||
        findBertCoreMLBlock(session.get(), "group.1-23-conv") == nullptr) {
        g_last_error = "Core ML BERT bundle requires prefix.0 and group.1-23-conv models: ";
        g_last_error += coreMLBertBlocksManifestPathForBertPath(bertPath).UTF8String;
        return nullptr;
    }
    return session.release();
}

+ (NSData *)runBertInferenceDataWithSession:(void *)session
                              tokenIdsData:(NSData *)tokenIdsData
                         attentionMaskData:(NSData *)attentionMaskData {
    g_last_error.clear();
    if (session == nullptr || tokenIdsData.length == 0 ||
        tokenIdsData.length % sizeof(int64_t) != 0 ||
        attentionMaskData.length != tokenIdsData.length) {
        g_last_error = "Core ML BERT input length mismatch or missing session";
        return [NSData data];
    }
    auto *sb = static_cast<StyleBertVits2Session *>(session);
    auto tokens = toInt64VectorFromData(tokenIdsData);
    auto masks = toInt64VectorFromData(attentionMaskData);
    auto *prefix = findBertCoreMLBlock(sb, "prefix.0");
    auto *group = findBertCoreMLBlock(sb, "group.1-23-conv");
    auto paddedTokens = tokens;
    auto paddedMasks = masks;
    if (!group->sequenceLengthCandidates.empty()) {
        auto candidate = std::lower_bound(group->sequenceLengthCandidates.begin(),
                                         group->sequenceLengthCandidates.end(),
                                         static_cast<int64_t>(tokens.size()));
        if (candidate == group->sequenceLengthCandidates.end()) {
            g_last_error = "BERT token length exceeds CoreML shape candidates";
            return [NSData data];
        }
        paddedTokens.resize(static_cast<size_t>(*candidate), 0);
        paddedMasks.resize(static_cast<size_t>(*candidate), 0);
    }
    NSData *residual = nil;
    NSData *hidden = runBertCoreMLBlockEmbeddingsData(prefix, paddedTokens, paddedMasks, &residual);
    if (hidden.length == 0 || residual.length == 0) return [NSData data];
    NSData *output = runBertCoreMLBlockTwoFloatInputsAndMaskData(
        group, hidden, residual, paddedMasks, "Core ML BERT group.1-23-conv");
    const size_t expectedBytes = paddedMasks.size() * 1024 * sizeof(float);
    if (output.length != expectedBytes) {
        if (g_last_error.empty()) g_last_error = "Core ML BERT output shape mismatch";
        return [NSData data];
    }
    return [output subdataWithRange:NSMakeRange(0, tokens.size() * 1024 * sizeof(float))];
}

+ (NSData *)expandBertFeaturesData:(NSData *)bertFeaturesData
                       word2phData:(NSData *)word2phData
                          tokenLen:(NSInteger)tokenLen
                        featureDim:(NSInteger)featureDim {
    g_last_error.clear();
    if (tokenLen <= 0 || featureDim <= 0 ||
        bertFeaturesData.length / sizeof(float) / static_cast<size_t>(featureDim) != tokenLen ||
        bertFeaturesData.length % (sizeof(float) * static_cast<size_t>(featureDim)) != 0 ||
        word2phData.length % sizeof(int32_t) != 0 ||
        word2phData.length / sizeof(int32_t) > tokenLen) {
        g_last_error = "BERT feature expansion input shape mismatch";
        return [NSData data];
    }
    std::vector<float> bert = toFloatVectorFromData(bertFeaturesData);
    std::vector<int64_t> word2phVec = toInt64VectorFromInt32Data(word2phData);

    int phonemeLen = 0;
    for (int64_t value : word2phVec) {
        if (value < 0 || value > std::numeric_limits<int>::max() / featureDim - phonemeLen) {
            g_last_error = "BERT feature expansion invalid phoneme count";
            return [NSData data];
        }
        phonemeLen += (int)value;
    }

    int outputSize = (int)featureDim * phonemeLen;
    std::vector<float> output(outputSize);

    int outIdx = 0;
    for (size_t i = 0; i < word2phVec.size(); i++) {
        int repeat = (int)word2phVec[i];
        for (int r = 0; r < repeat; r++) {
            for (int d = 0; d < featureDim; d++) {
                output[outIdx * featureDim + d] = bert[i * featureDim + d];
            }
            outIdx++;
        }
    }

    return dataFromFloatVector(output);
}

+ (void)releaseSession:(void *)session {
    delete static_cast<StyleBertVits2Session *>(session);
}

+ (NSString *)lastError {
    return [NSString stringWithUTF8String:g_last_error.c_str()];
}
@end
