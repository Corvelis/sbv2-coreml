# Licensing and provenance

[日本語（メイン）](THIRD_PARTY_NOTICES.md)

[日本語の案内](docs/licenses.ja.md)

## Code

This source distribution and its modifications are provided under **AGPL-3.0** (`LICENSE`).
It includes/adapts Style-Bert-VITS2 model-conversion and Japanese frontend logic. Do not treat
the Swift port as a blanket MIT/Apache exception to the upstream terms. This release does
not offer a permissive license for embedding the complete library in closed-source apps.
AGPL obligations, including corresponding source where applicable, remain relevant.

- **Style-Bert-VITS2**, litagin and contributors: https://github.com/litagin02/Style-Bert-VITS2
  pinned commit `66de777e06392c0f313600be03c43ef96658b244`, AGPL-3.0.
  The upstream repository identifies LGPL-3.0 for portions of user dictionary code;
  its license is retained in `LICENSES/SBV2-LGPL-3.0.txt`.
- **StackChan Talk / Local AI native implementation**: code extracted from the local source
  project with its Apache-2.0 notice retained in `LICENSES/LocalAI-Apache-2.0.txt`.
  The extraction inventory records original file hashes. The combined work is distributed
  under AGPL-3.0 while preserving existing third-party notices.
- **Open JTalk**, HTS Working Group / Nagoya Institute of Technology, BSD-style terms:
  `LICENSES/OpenJTalk-COPYING`, authors in `LICENSES/OpenJTalk-AUTHORS`.
- **MeCab**, Taku Kudo / NTT and contributors, bundled BSD terms:
  `LICENSES/OpenJTalk-mecab-COPYING`. Original notices remain in source files.
- **Transformers DeBERTa**, Hugging Face contributors, Apache-2.0. The BERT exporter uses
  and adapts its forward operations: https://github.com/huggingface/transformers.
  See `LICENSES/Transformers-Apache-2.0.txt`.
- **Core ML Tools**, Apple, BSD-3-Clause: https://github.com/apple/coremltools.
  Python dependency, not included in the Swift application. Its license is retained in `LICENSES`.
- **PyTorch**, its contributors, BSD-style terms; **NumPy**, NumPy developers, BSD-3-Clause;
  **Safetensors**, Hugging Face, Apache-2.0. Installed Python dependencies retain their own licenses.

Extraction changes include a public asynchronous Swift wrapper, standalone package targets,
sentence/capacity segmentation, download verification, sample applications, direct decoder
conversion, input normalization and release tools. `docs/source-inventory.json` records the
starting files. The upstream source downloaded by the converter retains its own full notices.

## Models and dictionary

Code licensing does not replace the conditions on downloaded weights and datasets.

- **JVNV F1 JP-Extra**, litagin, https://huggingface.co/litagin/style_bert_vits2_jvnv,
  revision `205830ca1d49e666ddfbf2a755f0108e9cade4dd`, trained from the JVNV corpus.
  Original/converted weights: CC BY-SA 4.0 (`LICENSES/CC-BY-SA-4.0.txt`).
- **Japanese DeBERTa**, Kyoto University NLP group,
  https://huggingface.co/ku-nlp/deberta-v2-large-japanese-char-wwm,
  revision `547b0e8b044fba3f9b84d0ab9f990440bd130c8b`, CC BY-SA 4.0.
- **Open JTalk UTF-8 dictionary 1.11**, NAIST and UniDic Consortium contributors:
  `LICENSES/OpenJTalk-Dictionary.txt` and the original `COPYING` shipped with the dictionary.
  The release download source/hash is in `docs/dictionary-source.json`.
- **AivisHub models**: each input's license applies. AIVM license text is preserved;
  ACML, ACML-NC and custom licenses must not be conflated. Converting a model does not
  grant redistribution rights or rights to character imagery, logos or names.

No model weights or compiled caches are committed to the source repository. Prepared HF
folders carry their own attribution, license, conversion description and hashes. The
conversions are unofficial and are not endorsed by the original creators.
