#!/usr/bin/env python3
"""Create local Hugging Face upload folders; never uploads or changes the input models."""
import argparse
import hashlib
import json
import os
import shutil
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]

def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda: stream.read(1024*1024),b''):h.update(data)
    return h.hexdigest()

def write(path, value): path.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n')

def copy_assets(source,destination):
    destination.mkdir(parents=True,exist_ok=True)
    for p in source.rglob('*'):
        relative=p.relative_to(source)
        if any(part.startswith('.') or part.endswith('.mlmodelc') for part in relative.parts):continue
        q=destination/relative
        if p.is_symlink():raise ValueError(f'Symlink in source: {p}')
        if p.is_dir():q.mkdir(parents=True,exist_ok=True)
        elif p.is_file():
            q.parent.mkdir(parents=True,exist_ok=True)
            # Immutable weight files may share storage with local input artifacts.
            # Metadata is copied because the release adds notices and portable manifests.
            if p.suffix=='.bin':
                try:os.link(p,q)
                except OSError:shutil.copy2(p,q)
            else:shutil.copy2(p,q)

def seal(root):
    checks={str(p.relative_to(root)):sha(p) for p in sorted(root.rglob('*')) if p.is_file()
        and p.name not in ('checksums.json','download.json')
        and not any(part.startswith('.') or part.endswith('.mlmodelc') for part in p.relative_to(root).parts)}
    write(root/'checksums.json',checks)
    entries=[*checks,'checksums.json']
    write(root/'download.json',{'formatVersion':1,'name':root.name,'files':[
        {'path':name,'sha256':sha(root/name),'bytes':(root/name).stat().st_size} for name in entries]})

def link_huggingface_cards(common, voice, owner):
    """Add companion-repository links before sealing a publisher's upload folders."""
    if not owner or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in owner):
        raise ValueError('Hugging Face owner must be a user or organization name')
    for folder, companion in ((common, voice), (voice, common)):
        readme = folder/'README.md'
        text = readme.read_text()
        section = f'''## Model repositories

This package: [{owner}/{folder.name}](https://huggingface.co/{owner}/{folder.name}).
Required companion: [{owner}/{companion.name}](https://huggingface.co/{owner}/{companion.name}).
Download the complete repository contents, preserving all `.mlpackage` folders.
Use a pinned commit revision for reproducible downloads.
Private repositories require an authenticated Hugging Face client; download them
to a local folder and select that folder in the sample. The sample's HTTPS
manifest downloader uses public repositories and does not accept access tokens.

'''
        text = text.replace('## Attribution and changes\n', section+'## Attribution and changes\n', 1)
        readme.write_text(text)

def link_source_cards(common, voice, source_url):
    """Link the separately distributed code without changing any model weights."""
    parsed = urlparse(source_url)
    if parsed.scheme != 'https' or not parsed.netloc or any(c.isspace() for c in source_url):
        raise ValueError('Source URL must be an HTTPS repository or release URL')
    marker = '\n## SDK, sample apps and converter\n'
    for folder in (common, voice):
        readme = folder/'README.md'
        text = readme.read_text().partition(marker)[0].rstrip()
        readme.write_text(text+marker+f'''
[SBV2 Core ML source and documentation]({source_url}) includes the Swift SDK,
iPhone/Mac sample apps, and AIVM/Safetensors voice conversion tools.
Follow the repository's Quick Start and SDK guide to use these models.
The code is AGPL-3.0; model and dictionary licenses are listed above.
''')

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('bert','voice','dictionary','output'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--bert-checkpoint',type=Path,required=True)
    parser.add_argument('--hf-owner',help='Hugging Face user or organization for companion-repository links')
    parser.add_argument('--source-url',help='HTTPS URL of the separately distributed source release')
    args=parser.parse_args()
    if args.output.exists():raise ValueError('Use a new output directory')
    provenance=json.loads((args.voice/'provenance.json').read_text())
    if provenance.get('checkpoint_sha256')!='a90fa6c9444d9235c9ec4db99daf7c5c6a21cc26ca141b4c48455d66a3257d01':
        raise ValueError('This release recipe is only for the pinned JVNV F1 JP-Extra checkpoint')
    if sha(args.bert_checkpoint/'model.safetensors')!='2630f547d018524a7b03506a42c700cbac49e29bdc441845b0615bfb3b5d74d2':
        raise ValueError('Shared BERT checkpoint does not match the pinned release source')
    dictionary_source=json.loads((ROOT/'docs/dictionary-source.json').read_text())
    for name,expected in dictionary_source['files'].items():
        if sha(args.dictionary/name)!=expected:raise ValueError(f'Dictionary differs from the release source: {name}')
    common=args.output/'sbv2-coreml-common';voice=args.output/'sbv2-coreml-jvnv-f1-jp'
    copy_assets(args.bert,common/'bert');copy_assets(args.dictionary,common/'dictionary');copy_assets(args.voice,voice)
    license_file=ROOT/'LICENSES/CC-BY-SA-4.0.txt'
    shutil.copy2(license_file,common/'LICENSE.md');shutil.copy2(license_file,voice/'LICENSE.md')
    # The model directory uses an existing native-compatible layout.
    write(common/'model.json',{'format_version':1,'kind':'common','name':'sbv2-coreml-common',
        'shared_bert':'deberta-v2-large-japanese-char-wwm-coreml-v1','minimum_ios':'18.0','minimum_macos':'15.0',
        'bert_directory':'bert','dictionary_directory':'dictionary','license_id':'cc-by-sa-4.0',
        'dictionary_license':'BSD notices in dictionary/COPYING'})
    checkpoint=args.bert_checkpoint
    write(common/'provenance.json',{'bert':{'repository':'ku-nlp/deberta-v2-large-japanese-char-wwm',
        'revision':'547b0e8b044fba3f9b84d0ab9f990440bd130c8b',
        'inputs':{p.name:sha(p) for p in checkpoint.iterdir() if p.is_file()}},
        'dictionary':dictionary_source,
        'conversion':'FP32 prefix.0 and group.1-23-conv, EnumeratedShapes 64/128/256; no quantization'})
    (common/'README.md').write_text('''---
license: cc-by-sa-4.0
language: ja
tags: [coreml, style-bert-vits2]
base_model: ku-nlp/deberta-v2-large-japanese-char-wwm
---
# SBV2 Core ML shared Japanese resources

Shared BERT for the SBV2CoreML Swift library, iOS 18+ / macOS 15+ Apple Silicon.
Download once and reuse across compatible JP-Extra voices. This package also
contains the Open JTalk 1.11 UTF-8 dictionary under its separate BSD notices.

## Attribution and changes

BERT: Kyoto University NLP group, [original model](https://huggingface.co/ku-nlp/deberta-v2-large-japanese-char-wwm),
revision `547b0e8b044fba3f9b84d0ab9f990440bd130c8b`. Converted to two FP32 Core ML
ML Programs with fixed candidate lengths 64/128/256. No retraining or quantization.
Original and converted BERT: CC BY-SA 4.0, see LICENSE.md.
Dictionary: Open JTalk / NAIST / UniDic contributors, see dictionary/COPYING.
These are unofficial conversions, without endorsement by the original authors.

## Usage

Pass `bert/` and `dictionary/` to `ModelPaths`; obtain a voice separately.
The sample app can import this entire folder as BERT and find the dictionary.
It can also download from the HTTPS URL of `download.json` at a pinned revision.
`checksums.json` records every distributed asset. Model compilation happens locally
on first use; compiled caches are not part of this upload.

Inference is offline. The SBV2CoreML application code has its own AGPL-3.0 license.
See the accompanying source release for setup and performance measurements.
''')
    (voice/'README.md').write_text('''---
license: cc-by-sa-4.0
language: ja
pipeline_tag: text-to-speech
tags: [coreml, style-bert-vits2, jp-extra]
base_model: litagin/style_bert_vits2_jvnv
---
# JVNV F1 JP-Extra for Core ML

One Japanese voice for the SBV2CoreML Swift library, iOS 18+ / macOS 15+ Apple Silicon.
Common BERT and an Open JTalk dictionary are required separately.

## Attribution and changes

Original model: litagin, [Style-Bert-VITS2 JVNV](https://huggingface.co/litagin/style_bert_vits2_jvnv),
`jvnv-F1-jp/jvnv-F1-jp_e160_s14000.safetensors`, revision
`205830ca1d49e666ddfbf2a755f0108e9cade4dd`. Trained on the
[JVNV corpus](https://sites.google.com/site/shinnosuketakamichi/research-topics/jvnv_corpus).
The original and this converted model are provided under CC BY-SA 4.0 (LICENSE.md).
This is an unofficial conversion, without endorsement by the original creators.

Converted from the original weights into Core ML encoder/DP, SDP, full-sentence
Flow and Decoder functions. A multifunction package shares identical weights
across shapes. There is no retraining or integer quantization. Fast decoder
functions use mixed FP32/FP16 precision; an FP32 reference decoder is retained.
This conversion is not bit-identical to the original PyTorch waveform.

## Usage and limits

Pass this folder as the voice in `ModelPaths`. Available styles are Neutral,
Angry, Disgust, Fear, Happy, Sad and Surprise; speaker ID is 0. Output is mono
44.1 kHz. Sentence segmentation and model capacity limits are handled by the
Swift library. Only compatible Japanese JP-Extra models are supported.

The sample can import this folder, or download `download.json` from a pinned
Hugging Face revision. All files have hashes. It compiles the model on first use.

## Validation

`waveform_validation.json` compares the FP32 full neural chain with PyTorch on
fixed synthetic inputs. `decoder_validation.json` reports FP32 and mixed precision
errors separately. `compaction_report.json` checks exact equality before/after
multifunction packaging. These tests do not establish identical voice quality
for every sentence. See the source release's verification report for native
device measurements and their scope; RTF 0.1 is not a universal guarantee.

The 2026-10-04 review of 0.1.0-dev1 covered eleven natural-text cases including
all seven styles. Whole-case SNR against the original FP32 voice was 46.05-47.01 dB,
with identical phoneme durations and sample counts; frontend/BERT features and noise
were shared for that comparison. The user listened through the comparison set and
judged it acceptable, while reporting extremely rare noise. The affected case and
original/Core ML variant were not identified. This is not a finding of zero noise.
See the source release's verification report for the complete scope and results.

The code and weights have separate licenses. The source release is AGPL-3.0.
''')
    if args.hf_owner:
        link_huggingface_cards(common,voice,args.hf_owner)
    if args.source_url:
        link_source_cards(common,voice,args.source_url)
    for path in (common,voice):
        (path/'.gitattributes').write_text('*.bin filter=lfs diff=lfs merge=lfs -text\n*.dic filter=lfs diff=lfs merge=lfs -text\n*.mlmodel filter=lfs diff=lfs merge=lfs -text\n')
        seal(path)
    print(args.output)

if __name__=='__main__':main()
