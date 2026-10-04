# Preparing and publishing a release

[日本語](releasing.ja.md) · [Documentation index](README.ja.md)

The repository prepares files locally. It never creates a remote repository or uploads weights automatically.

## Current upload status

Both model repositories were uploaded on 2026-10-04 and remain private:

| Repository | Pinned revision |
|---|---|
| [AILogDev/sbv2-coreml-common](https://huggingface.co/AILogDev/sbv2-coreml-common) | `94179fe62664d979791489969b5a9d1c1b335f34` |
| [AILogDev/sbv2-coreml-jvnv-f1-jp](https://huggingface.co/AILogDev/sbv2-coreml-jvnv-f1-jp) | `e5a48afa6244ecd5128b85496ad0afbbef37365e` |

All 41 files matched their local sizes and LFS SHA-256 or Git blob IDs; authenticated
HTTPS fetches of both pinned `download.json` manifests passed. See the
[upload record](verification/huggingface-upload-20261004.json).
The source GitHub repository/tag, model-card links to that tag, and anonymous sample
installation after switching the repositories to public remain pending.

## 1. Verify the code

```sh
swift test
python3 scripts/check_docs.py --swift
PYTHONPATH=converter .venv/bin/python -m unittest discover -s converter/tests -v
xcodebuild -project Examples/Apple/SBV2Demo.xcodeproj -scheme SBV2Demo-macOS \
  -configuration Release -destination 'platform=macOS,arch=arm64' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Examples/Apple/SBV2Demo.xcodeproj -scheme SBV2Demo-iOS \
  -configuration Release -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO build
```

Use `scripts/generate_xcode_project.rb` only to regenerate the checked-in project (requires the
`xcodeproj` Ruby gem). Sample users do not need Ruby or CocoaPods.

## 2. Prepare model repositories

Convert the JVNV F1 JP-Extra source with its CC BY-SA license, following `docs/conversion.md`.
Then run:

```sh
python3 scripts/prepare_release.py --bert /path/to/bert --voice /path/to/jvnv-f1-jp \
  --dictionary /path/to/open_jtalk_dic_utf_8-1.11 --bert-checkpoint /path/to/bert-checkpoint \
  --output artifacts/huggingface --hf-owner AILogDev
```

This release recipe is specifically for the named JVNV sample and pinned common BERT;
do not apply its model cards to another voice. It creates two local upload folders:
`sbv2-coreml-common` and `sbv2-coreml-jvnv-f1-jp`. The shared package includes the dictionary
under its separate notices. Immutable weight files may be hard-linked locally to save space.
Copy the folders normally when transferring to another machine; do not modify linked weights.
The optional `--hf-owner` adds the selected publisher's model-repository and companion links.

Only the files listed in `checksums.json`, plus `checksums.json`, `download.json`, and
`.gitattributes`, are release assets. Do not upload locally generated `.mlmodelc` caches.
`sbv2-coreml package` produces a checksum-listed archive excluding those caches.

Inspect licenses/model cards, verify checksums and test the model download path. Perform a
natural-text listening comparison for the voice/styles being released. Record device, OS,
thermal state, first-load versus warm timings and precision profile. Update `docs/verification.md`.

## 3. Publish after selecting the owner and reviewing the artifacts

- Create a GitHub repository for this source directory and push its own Git history.
- Create separate Hugging Face model repositories for common assets and the sample voice.
- Upload only the sealed assets; keep each model's own license and original-model attribution.
- Tag the code release; record the resulting HF commit revisions in the release notes.
- Link both model cards back to the actual GitHub tag and replace pre-publication URL text.
- Use immutable HF `resolve/<commit>/download.json` URLs in Quick Start instructions.

The default source distribution is AGPL-3.0. This preparation does not decide App Store
distribution compliance or grant a permissive commercial embedding license. If a permissive
SDK license is required, resolve code provenance/permissions before advertising that use.

## Device smoke test

Copy the two sealed folders into the iOS sample's Documents directory. Launch with
`--smoke-test` and optional `SBV2_TEST_SEED=20260928`. The sample records `sbv2-smoke.json`
and five WAVs there. No microphone, ASR or LLM is used in this test.

The Mac executable also accepts `--smoke-test`, `SBV2_SMOKE_ROOT` (parent of the two model
folders) and `SBV2_SMOKE_OUTPUT` (report directory). It remains an app process after testing.
Normal app operation requires no environment variables.
