# Model format v1

[日本語](model-format.ja.md) · [Documentation index](README.ja.md)

The Swift runtime loads the native-compatible directory layouts below. Release files also
include `model.json`, `provenance.json`, `LICENSE.md`, `checksums.json`, and `download.json`.

```text
common/
  bert/vocab.txt
  bert/coreml_blocks/coreml_bert_blocks_manifest.json
  bert/coreml_blocks/prefix.0_enum-int8-b32.mlpackage/
  bert/coreml_blocks/group.1-23-conv_enum-int8-b32.mlpackage/
  dictionary/{char.bin,matrix.bin,sys.dic,unk.dic,COPYING}
voice/
  config.json
  style_vectors.npy
  coreml_voice/coreml_voice_blocks_manifest.json
  coreml_voice/voice_shared.mlpackage/
```

The layout above is INT8. Original FP32 uses `prefix.0_enum.mlpackage` and `group.1-23-conv_enum.mlpackage`.
The SDK reads package paths from each variant's BERT manifest. See [model selection](model-selection.md) for downloads and switching.

Voice functions: `pre_64`, `pre_128`, `sdp_64`, `sdp_128`, `flow_64`, `flow_128`,
`flow_256`, `flow_512`, `decoder_combined_flex`, `decoder_combined_len_256_fp16`,
`decoder_combined_len_32_fp16`. No ONNX file is needed in either folder.

The shared BERT contract is `deberta-v2-large-japanese-char-wwm-coreml-v1`: vocab size
22012, 1024-dimensional features and Japanese character tokenization. Voice shapes use
192 latent/hidden channels, 512 speaker-condition channels and 256-dimensional styles.
Audio is mono Float32 44100 Hz, hop 512. Maximum phoneme count per model call is 128;
maximum predicted audio length is 512 frames. Decoder context is 13 frames for the validated
upsampling/residual architecture; Flow always sees the complete segment.

`checksums.json` maps relative filenames to SHA-256. `download.json` contains:

```json
{"formatVersion":1,"name":"voice","files":[
  {"path":"config.json","sha256":"<64 lowercase hex digits>","bytes":1234}
]}
```

This example describes the schema, not a usable manifest. Relative URLs are resolved next
to the manifest. Use a pinned Hugging Face revision to keep all files consistent. Downloads
are staged, checked and then installed. Paths containing traversal, duplicate entries or
invalid hashes are rejected. The manifest and its host must be trusted: hashes ensure file
consistency, not authorship of the manifest.

Compiled `.mlmodelc` directories are local caches, excluded from checksums/download manifests
and release archives. They may be deleted while the engine is unloaded; they will be rebuilt
at next load. Do not copy Mac caches to an iPhone or use them as canonical distribution files.
