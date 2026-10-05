# Choose INT8 or the original FP32 model

[日本語](model-selection.ja.md) · [Quick start](getting-started.ja.md) · [Sample app](sample-app.ja.md)

The shared BERT/dictionary has **INT8 in `int8/`** and **original FP32 in `float32/`**.
Each folder contains BERT, the dictionary, licenses and a download manifest.
Both work with the same SDK and separate compatible voice models. Voices do not need reconversion.

## Which to choose

| Comparison | INT8 | Original FP32 |
|---|---|---|
| Choose when | Storage size matters | Avoiding BERT weight quantization or shorter preparation matters |
| Shared BERT/dictionary | About 503 MB | About 1.52 GB |
| Total with JVNV voice | About 797 MB | About 1.81 GB |
| BERT weights | 8bit storage in blocks of 32 | Original unquantized FP32 |
| BERT computation and tensor interfaces | FP32 | FP32 |
| Example cached reload + warm-up | About 18 seconds | About 6 seconds |
| Example warmed median RTF | 0.071 | 0.067 |

Sizes describe distribution files, excluding compilation caches and temporary downloads. Storage savings do not establish RAM savings.
Timings were measured on iPhone 17 Pro with JVNV Neutral. Preparation had existing compilation caches;
RTF was measured for three sentences synthesized as one utterance, excluding loading and playback. No LLM ran concurrently.
Other texts, voices and devices can differ. INT8 is not necessarily faster.

Only shared BERT weights are quantized; voice weights and the dictionary are unchanged.
Rounding can change BERT features, prosody, timing, duration and waveform. No concerning difference was heard in the JVNV Neutral comparison clips;
compare your intended voices and texts as well. The FP32 option is the original converted Core ML model, not the PyTorch checkpoint.

## Download in the sample app

Open **モデル設定 → URLからモデルを取得**, choose **共通モデル**, then choose **INT8（約503 MB）** or **FP32（約1.52 GB）** in **共通モデルの版**.
The manifest URL is filled automatically; press **ダウンロード**.
These URLs pin all files to a specific revision.

**INT8**

```text
https://huggingface.co/AILogDev/sbv2-coreml-common/resolve/973d6e239af305f0d78a8bf30c6af5093c0fd47d/int8/download.json
```

**Original FP32**

```text
https://huggingface.co/AILogDev/sbv2-coreml-common/resolve/973d6e239af305f0d78a8bf30c6af5093c0fd47d/float32/download.json
```

Browse the [INT8 files](https://huggingface.co/AILogDev/sbv2-coreml-common/tree/973d6e239af305f0d78a8bf30c6af5093c0fd47d/int8) or [original FP32 files](https://huggingface.co/AILogDev/sbv2-coreml-common/tree/973d6e239af305f0d78a8bf30c6af5093c0fd47d/float32) separately.
Use the same voice download URL from the [quick start](getting-started.ja.md), or your own converted voice folder.

## Download on Mac

Use the [Hugging Face CLI](https://huggingface.co/docs/huggingface_hub/guides/cli) to download one variant.
Keep `--include`: omitting it downloads both variants and compatibility files.

**INT8**

```sh
hf download AILogDev/sbv2-coreml-common \
  --revision 973d6e239af305f0d78a8bf30c6af5093c0fd47d \
  --include "int8/*" --local-dir models
```

**Original FP32**

```sh
hf download AILogDev/sbv2-coreml-common \
  --revision 973d6e239af305f0d78a8bf30c6af5093c0fd47d \
  --include "float32/*" --local-dir models
```

Downloads go into `models/int8/` and `models/float32/`. Keep each complete folder. Do not overlay another variant or replace individual packages: that would invalidate its manifest and checksums.

## Switch models

**Sample app:** stop synthesis/playback, open **モデル設定 → 共通モデル**, choose the shared root containing `bert/` and `dictionary/`,
and press **モデルを準備**. Keep the same voice selection. The shared-folder label also shows INT8/FP32 from its metadata.
The download variant picker chooses a download source; the loaded variant comes from the selected folder after preparation.
Each URL download installs into a new folder and selects it. On iPhone, folders appear under **Files → On My iPhone → SBV2 Core ML**.
Folder selections may need to be repeated after restarting the sample.

**SDK:** set `ModelPaths.bert` and `ModelPaths.dictionary` to the selected shared folder's subdirectories. Retain the same `ModelPaths.voice`.
Stop synthesis and playback, await completion, then call `load` and `warmUp` in order. See the [SDK guide](sdk-guide.ja.md).

Adding INT8 does not remove an existing FP32 folder or its caches. To reclaim storage, quit the app or call `unload`,
then remove only the unused shared folder. Keep the separate voice folder. See [cache management](troubleshooting.ja.md).
To create your own compressed shared model, see the [compression guide](compression.md).
