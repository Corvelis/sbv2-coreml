// swift-tools-version: 5.9
import PackageDescription

let jt = "OpenJTalk/open_jtalk_src"
let folders = ["jpcommon", "mecab/src", "mecab2njd", "njd", "njd2jpcommon",
    "njd_set_accent_phrase", "njd_set_accent_type", "njd_set_digit", "njd_set_long_vowel",
    "njd_set_pronunciation", "njd_set_unvoiced_vowel", "text2mecab"]
let includes: [CSetting] = [.headerSearchPath("."), .headerSearchPath(jt)] + folders.map { .headerSearchPath("\(jt)/\($0)") }
let defines: [CSetting] = [.define("CHARSET_UTF_8", to: "1"), .define("HAVE_CONFIG_H", to: "1"),
    .define("DIC_VERSION", to: "102"), .define("MECAB_WITHOUT_MUTEX_LOCK", to: "1"),
    .define("MECAB_DEFAULT_RC", to: "\"dummy\""), .define("PACKAGE", to: "\"open_jtalk\""),
    .define("VERSION", to: "\"1.01\"")]
let package = Package(
    name: "SBV2CoreML",
    platforms: [.iOS("18.0"), .macOS("15.0")],
    products: [.library(name: "SBV2CoreML", targets: ["SBV2CoreML"]),
               .executable(name: "sbv2-say", targets: ["SBV2Say"])],
    targets: [
        .target(name: "SBV2Native", publicHeadersPath: "include", cSettings: includes + defines,
                linkerSettings: [.linkedLibrary("c++"), .linkedLibrary("iconv"), .linkedFramework("CoreML")]),
        .target(name: "SBV2CoreML", dependencies: ["SBV2Native"]),
        .executableTarget(name: "SBV2Say", dependencies: ["SBV2CoreML"], path: "Examples/CLI"),
        .testTarget(name: "SBV2CoreMLTests", dependencies: ["SBV2CoreML"])
    ], cxxLanguageStandard: .cxx17
)
