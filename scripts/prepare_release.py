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

def write_model_cards(common, voice):
    """Japanese is the primary model card; English is a separate companion."""
    for folder, kind in ((common, 'common'), (voice, 'voice')):
        for name in ('README.md', 'README.en.md'):
            shutil.copy2(ROOT/'scripts/model-cards'/kind/name, folder/name)


def link_huggingface_cards(common, voice, owner):
    """Add companion-repository links in both documentation languages."""
    if not owner or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_' for c in owner):
        raise ValueError('Hugging Face owner must be a user or organization name')
    for folder, companion in ((common, voice), (voice, common)):
        for name in ('README.md', 'README.en.md'):
            readme = folder/name
            if name == 'README.md':
                marker = '## 出典と変換内容\n'
                section = f'''## 配布先

このパッケージ：[{owner}/{folder.name}](https://huggingface.co/{owner}/{folder.name})。
併せて必要なパッケージ：[{owner}/{companion.name}](https://huggingface.co/{owner}/{companion.name})。
`.mlpackage`を含めた全ファイルを、フォルダ構成のまま取得してください。
再現可能な取得には固定コミットを指定します。
Privateの場合は認証付きのHugging Faceクライアントで取得し、サンプルでローカルフォルダを選びます。
サンプルのHTTPS取得はPublic向けで、アクセストークンの入力機能はありません。

'''
            else:
                marker = '## Attribution and changes\n'
                section = f'''## Model repositories

This package: [{owner}/{folder.name}](https://huggingface.co/{owner}/{folder.name}).
Required companion: [{owner}/{companion.name}](https://huggingface.co/{owner}/{companion.name}).
Download the complete repository contents, preserving all `.mlpackage` folders.
Use a pinned commit revision for reproducible downloads.
Private repositories require an authenticated Hugging Face client; download them
locally and select that folder. The sample's HTTPS downloader does not accept tokens.

'''
            text = readme.read_text()
            if marker not in text:
                raise ValueError(f'Model card is missing its attribution section: {readme}')
            readme.write_text(text.replace(marker, section+marker, 1))


def link_source_cards(common, voice, source_url):
    """Link separately distributed code without changing model weights."""
    parsed = urlparse(source_url)
    if parsed.scheme != 'https' or not parsed.netloc or any(c.isspace() for c in source_url):
        raise ValueError('Source URL must be an HTTPS repository or release URL')
    for folder in (common, voice):
        for name in ('README.md', 'README.en.md'):
            readme = folder/name
            if name == 'README.md':
                marker = '\n\n## SDK・サンプル・変換ツール\n'
                section = f'''
[SBV2 Core MLのソースと日本語ドキュメント]({source_url})に、Swift SDK、
iPhone／Macサンプル、AIVM／Safetensorsからの声モデル変換ツールを含めています。
導入方法はリポジトリのクイックスタートとSDKガイドを参照してください。
コードはAGPL-3.0、モデル・辞書の条件は上記のとおりです。
'''
            else:
                marker = '\n\n## SDK, sample apps and converter\n'
                section = f'''
[SBV2 Core ML source and documentation]({source_url}) includes the Swift SDK,
iPhone/Mac sample apps and AIVM/Safetensors voice conversion tools.
The main documentation is Japanese, with an English README as a supplement.
The code is AGPL-3.0; model and dictionary licenses are listed above.
'''
            readme.write_text(readme.read_text().partition(marker)[0].rstrip()+marker+section)

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
    write_model_cards(common, voice)
    if args.hf_owner:
        link_huggingface_cards(common,voice,args.hf_owner)
    if args.source_url:
        link_source_cards(common,voice,args.source_url)
    for path in (common,voice):
        (path/'.gitattributes').write_text('*.bin filter=lfs diff=lfs merge=lfs -text\n*.dic filter=lfs diff=lfs merge=lfs -text\n*.mlmodel filter=lfs diff=lfs merge=lfs -text\n')
        seal(path)
    print(args.output)

if __name__=='__main__':main()
