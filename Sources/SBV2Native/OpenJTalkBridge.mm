#import "OpenJTalkBridge.h"
#import <Foundation/Foundation.h>
#include <mutex>
#include <vector>
#include <string>
#include <cstring>

// OpenJTalk headers - include order matters.
extern "C" {
#include "OpenJTalk/open_jtalk_src/text2mecab/text2mecab.h"
#include "OpenJTalk/open_jtalk_src/njd/njd.h"
#include "OpenJTalk/open_jtalk_src/jpcommon/jpcommon.h"
#include "OpenJTalk/open_jtalk_src/mecab2njd/mecab2njd.h"
#include "OpenJTalk/open_jtalk_src/njd_set_pronunciation/njd_set_pronunciation.h"
#include "OpenJTalk/open_jtalk_src/njd_set_digit/njd_set_digit.h"
#include "OpenJTalk/open_jtalk_src/njd_set_accent_phrase/njd_set_accent_phrase.h"
#include "OpenJTalk/open_jtalk_src/njd_set_accent_type/njd_set_accent_type.h"
#include "OpenJTalk/open_jtalk_src/njd_set_unvoiced_vowel/njd_set_unvoiced_vowel.h"
#include "OpenJTalk/open_jtalk_src/njd_set_long_vowel/njd_set_long_vowel.h"
#include "OpenJTalk/open_jtalk_src/njd2jpcommon/njd2jpcommon.h"

// MeCab C API forward declarations (mecab.h has C++ templates).
typedef struct _Mecab {
    char **feature;
    int size;
    void *mecab;
} Mecab;

#define BOOL int
void Mecab_initialize(Mecab *m);
BOOL Mecab_load(Mecab *m, const char *dicdir);
BOOL Mecab_analysis(Mecab *m, const char *str);
BOOL Mecab_print(Mecab *m);
int Mecab_get_size(Mecab *m);
char **Mecab_get_feature(Mecab *m);
BOOL Mecab_refresh(Mecab *m);
BOOL Mecab_clear(Mecab *m);
}

namespace {

struct OpenJTalkHandle {
    std::mutex mutex;
    bool firstCall;
    NJD njd;
    JPCommon jpcommon;
    Mecab mecab;

    OpenJTalkHandle() : firstCall(true) {
        memset(&njd, 0, sizeof(NJD));
        memset(&jpcommon, 0, sizeof(JPCommon));
        memset(&mecab, 0, sizeof(Mecab));
        NJD_initialize(&njd);
        JPCommon_initialize(&jpcommon);
        Mecab_initialize(&mecab);
    }

    ~OpenJTalkHandle() {
        NJD_clear(&njd);
        JPCommon_clear(&jpcommon);
        Mecab_clear(&mecab);
    }
};

static NSDictionary<NSString *, id> *nodeToDictionary(NJDNode *node) {
    if (node == nullptr) {
        return @{};
    }
    return @{
        @"string": NJDNode_get_string(node) ? [NSString stringWithUTF8String:NJDNode_get_string(node)] : @"",
        @"pos": NJDNode_get_pos(node) ? [NSString stringWithUTF8String:NJDNode_get_pos(node)] : @"",
        @"pos_group1": NJDNode_get_pos_group1(node) ? [NSString stringWithUTF8String:NJDNode_get_pos_group1(node)] : @"",
        @"pos_group2": NJDNode_get_pos_group2(node) ? [NSString stringWithUTF8String:NJDNode_get_pos_group2(node)] : @"",
        @"pos_group3": NJDNode_get_pos_group3(node) ? [NSString stringWithUTF8String:NJDNode_get_pos_group3(node)] : @"",
        @"ctype": NJDNode_get_ctype(node) ? [NSString stringWithUTF8String:NJDNode_get_ctype(node)] : @"",
        @"cform": NJDNode_get_cform(node) ? [NSString stringWithUTF8String:NJDNode_get_cform(node)] : @"",
        @"orig": NJDNode_get_orig(node) ? [NSString stringWithUTF8String:NJDNode_get_orig(node)] : @"",
        @"read": NJDNode_get_read(node) ? [NSString stringWithUTF8String:NJDNode_get_read(node)] : @"",
        @"pron": NJDNode_get_pron(node) ? [NSString stringWithUTF8String:NJDNode_get_pron(node)] : @"",
        @"acc": @(NJDNode_get_acc(node)),
        @"mora_size": @(NJDNode_get_mora_size(node)),
        @"chain_rule": NJDNode_get_chain_rule(node) ? [NSString stringWithUTF8String:NJDNode_get_chain_rule(node)] : @"",
        @"chain_flag": @(NJDNode_get_chain_flag(node)),
    };
}

static void dictionaryToNJD(NSArray<NSDictionary<NSString *, id> *> *features, NJD *njd) {
    for (NSDictionary<NSString *, id> *map in features) {
        NJDNode *node = (NJDNode *)calloc(1, sizeof(NJDNode));
        NJDNode_initialize(node);

        auto getString = ^const char * (NSString *key) {
            id value = map[key];
            if (![value isKindOfClass:[NSString class]]) {
                return "";
            }
            return [(NSString *)value UTF8String];
        };

        auto getInt = ^int (NSString *key) {
            id value = map[key];
            if (![value isKindOfClass:[NSNumber class]]) {
                return 0;
            }
            return [(NSNumber *)value intValue];
        };

        NJDNode_set_string(node, getString(@"string"));
        NJDNode_set_pos(node, getString(@"pos"));
        NJDNode_set_pos_group1(node, getString(@"pos_group1"));
        NJDNode_set_pos_group2(node, getString(@"pos_group2"));
        NJDNode_set_pos_group3(node, getString(@"pos_group3"));
        NJDNode_set_ctype(node, getString(@"ctype"));
        NJDNode_set_cform(node, getString(@"cform"));
        NJDNode_set_orig(node, getString(@"orig"));
        NJDNode_set_read(node, getString(@"read"));
        NJDNode_set_pron(node, getString(@"pron"));
        NJDNode_set_acc(node, getInt(@"acc"));
        NJDNode_set_mora_size(node, getInt(@"mora_size"));
        NJDNode_set_chain_rule(node, getString(@"chain_rule"));
        NJDNode_set_chain_flag(node, getInt(@"chain_flag"));

        NJD_push_node(njd, node);
    }
}

}

@implementation StyleBertVits2OpenJTalkBridge

+ (void *)initializeWithDicPath:(NSString *)dicPath {
    const char *dicPathChars = [dicPath UTF8String];
    if (dicPathChars == nullptr) {
        return nullptr;
    }

    OpenJTalkHandle *handle = new OpenJTalkHandle();
    if (Mecab_load(&handle->mecab, dicPathChars) != 1) {
        delete handle;
        return nullptr;
    }
    return reinterpret_cast<void *>(handle);
}

+ (NSArray<NSDictionary<NSString *, id> *> *)runFrontend:(void *)handle text:(NSString *)text {
    auto *jt = reinterpret_cast<OpenJTalkHandle *>(handle);
    if (jt == nullptr) {
        return @[];
    }

    std::lock_guard<std::mutex> lock(jt->mutex);

    if (!jt->firstCall) {
        Mecab_refresh(&jt->mecab);
        NJD_refresh(&jt->njd);
        JPCommon_refresh(&jt->jpcommon);
    } else {
        jt->firstCall = false;
    }

    const char *textChars = [text UTF8String];
    if (textChars == nullptr) {
        return @[];
    }

    char buff[8192];
    text2mecab(buff, textChars);
    Mecab_analysis(&jt->mecab, buff);

    int mecabSize = Mecab_get_size(&jt->mecab);
    if (mecabSize <= 0) {
        return @[];
    }

    char **features = Mecab_get_feature(&jt->mecab);
    for (int i = 0; i < mecabSize; i++) {
        NJDNode *node = (NJDNode *)calloc(1, sizeof(NJDNode));
        NJDNode_initialize(node);
        NJDNode_load(node, features[i]);
        NJD_push_node(&jt->njd, node);
    }

    njd_set_pronunciation(&jt->njd);
    njd_set_digit(&jt->njd);
    njd_set_accent_phrase(&jt->njd);
    njd_set_accent_type(&jt->njd);
    njd_set_unvoiced_vowel(&jt->njd);
    njd_set_long_vowel(&jt->njd);

    NSMutableArray<NSDictionary<NSString *, id> *> *results = [NSMutableArray array];
    for (NJDNode *node = jt->njd.head; node != nullptr; node = node->next) {
        [results addObject:nodeToDictionary(node)];
    }

    return results;
}

+ (NSArray<NSString *> *)makeLabel:(void *)handle features:(NSArray<NSDictionary<NSString *, id> *> *)features {
    auto *jt = reinterpret_cast<OpenJTalkHandle *>(handle);
    if (jt == nullptr) {
        return @[];
    }

    std::lock_guard<std::mutex> lock(jt->mutex);

    NJD_refresh(&jt->njd);
    dictionaryToNJD(features, &jt->njd);

    njd2jpcommon(&jt->jpcommon, &jt->njd);
    JPCommon_make_label(&jt->jpcommon);

    int labelSize = JPCommon_get_label_size(&jt->jpcommon);
    char **labelFeature = JPCommon_get_label_feature(&jt->jpcommon);

    NSMutableArray<NSString *> *labels = [NSMutableArray arrayWithCapacity:labelSize];
    for (int i = 0; i < labelSize; i++) {
        NSString *label = labelFeature[i] ? [NSString stringWithUTF8String:labelFeature[i]] : @"";
        [labels addObject:label];
    }

    JPCommon_refresh(&jt->jpcommon);
    NJD_refresh(&jt->njd);

    return labels;
}

+ (void)releaseHandle:(void *)handle {
    auto *jt = reinterpret_cast<OpenJTalkHandle *>(handle);
    if (jt != nullptr) {
        delete jt;
    }
}

@end
