"""Distribution CLI. Heavy ML imports happen only in conversion workers."""
from __future__ import annotations
import argparse
import importlib.metadata
import json
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from . import __version__
from .assets import (ARCHITECTURE, UPSTREAM_REVISION, aivis_metadata, digest, extract_aivm,
                     fetch_aivis, upstream, prepare_upstream, validate_config, write_json)

def worker(script: str, *args) -> None:
    subprocess.run([sys.executable, '-m', script, *map(str, args)], check=True)

def convert(args):
    if platform.system() != 'Darwin': raise ValueError('Conversion and validation require macOS')
    destination = args.output.resolve()
    if destination.exists(): raise ValueError('Output already exists; choose a new directory')
    cache = args.cache.resolve(); cache.mkdir(parents=True, exist_ok=True)
    source = args.source_root.resolve() if args.source_root else upstream(cache / 'source')
    if not (source / 'style_bert_vits2/models/infer.py').is_file(): raise ValueError('Invalid upstream source root')
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Temporary outputs are removed on failure/success, never installed over a working voice.
    with tempfile.TemporaryDirectory(prefix='.sbv2-convert-', dir=destination.parent) as temp:
        work = Path(temp); provenance = {}
        checkpoint = args.aivm or args.checkpoint
        if args.aivis_url: checkpoint, provenance = fetch_aivis(args.aivis_url, cache / 'aivis')
        checkpoint = checkpoint.resolve()
        if checkpoint.suffix == '.aivmx': raise ValueError('AIVMX alone is unsupported; supply original AIVM/Safetensors weights')
        license_file = args.license_file
        if checkpoint.suffix == '.aivm':
            config, styles, embedded = extract_aivm(checkpoint, work / 'input')
            provenance['aivm'] = embedded
            if not license_file and (work / 'input/LICENSE.md').is_file(): license_file = work / 'input/LICENSE.md'
        else:
            config = args.config or checkpoint.parent / 'config.json'
            styles = args.styles or checkpoint.parent / 'style_vectors.npy'
        configuration = validate_config(config, styles)
        if args.source_url: provenance['url'] = args.source_url
        provenance.update(checkpoint_sha256=digest(checkpoint), config_sha256=digest(config), styles_sha256=digest(styles),
                          converter_version=__version__, upstream_revision=UPSTREAM_REVISION if not args.source_root else 'user-supplied-source')
        provenance['upstream_source_files'] = {str(p.relative_to(source)): digest(p) for p in sorted((source / 'style_bert_vits2').rglob('*.py'))}
        provenance['upstream_compatibility_patch'] = prepare_upstream(source, work / 'upstream')
        source = work / 'upstream'
        raw = work / 'voice'; blocks = raw / 'coreml_voice'; decoder = raw / 'hybrid'
        raw.mkdir(); shutil.copy2(config, raw / 'config.json'); shutil.copy2(styles, raw / 'style_vectors.npy')
        if license_file: shutil.copy2(license_file, raw / 'LICENSE.md')
        worker('sbv2_coreml._conversion.build_coreml_voice_from_checkpoint', '--source-root', source,
            '--checkpoint', checkpoint, '--config', config, '--output-dir', blocks, '--validate')
        worker('sbv2_coreml.decoder', '--source-root', source, '--checkpoint', checkpoint, '--config', config, '--output', decoder)
        validation = work / 'waveform_validation.json'
        worker('sbv2_coreml._conversion.validate_voice_coreml_pipeline', '--source-root', source,
            '--checkpoint', checkpoint, '--config', config, '--style-vectors', styles, '--coreml-blocks', blocks,
            '--decoder', decoder / 'decoder_combined_flex.mlpackage', '--json-out', validation)
        report = json.loads(validation.read_text())
        if report['waveform']['snr_db'] < 60 or report['waveform']['max_abs'] > 1e-3:
            raise ValueError(f"Waveform check failed: {report['waveform']}")
        worker('sbv2_coreml._conversion.compact_coreml_voice', '--source', raw, '--destination', work / 'compact')
        compact = work / 'compact'
        shutil.copy2(validation, compact / 'waveform_validation.json')
        shutil.copy2(decoder / 'decoder_validation.json', compact / 'decoder_validation.json')
        # Reports must be portable and must not expose the converter user's local paths.
        def portable(value):
            if isinstance(value, dict): return {k: portable(v) for k,v in value.items()}
            if isinstance(value, list): return [portable(v) for v in value]
            if isinstance(value, str) and value.startswith('/'): return Path(value).name
            return value
        for path in compact.rglob('*.json'):
            write_json(path, portable(json.loads(path.read_text())))
        write_json(compact / 'provenance.json', provenance)
        write_json(compact / 'model.json', {'format_version': 1, 'kind': 'voice', 'architecture': ARCHITECTURE,
            'name': args.name or destination.name, 'sample_rate': 44100, 'hop_length': 512,
            'style_dimension': 256, 'bert_feature_dimension': 1024, 'decoder_context_frames': 13,
            'text_lengths': [64,128], 'flow_lengths': [64,128,256,512],
            'shared_bert': 'deberta-v2-large-japanese-char-wwm-coreml-v1',
            'minimum_ios': '18.0', 'minimum_macos': '15.0', 'quantization': 'none',
            'decoder_precision': {r['name']: r['precision'] for r in json.loads((decoder / 'decoder_validation.json').read_text())}, 'license_id': args.license_id,
            'speakers': configuration['data']['spk2id'], 'styles': configuration['data']['style2id']})
        write_json(compact / 'checksums.json', {str(p.relative_to(compact)): digest(p) for p in sorted(compact.rglob('*')) if p.is_file()})
        compact.rename(destination)
    print(f'Voice ready: {destination}')

def verify(directory: Path) -> dict:
    directory = directory.resolve()
    checksums = json.loads((directory / 'checksums.json').read_text())
    if not checksums: raise ValueError('Empty checksums manifest')
    for name, checksum in checksums.items():
        if not isinstance(name, str) or any(part in ('', '.', '..') for part in name.split('/')) or '\\' in name or ':' in name:
            raise ValueError(f'Invalid asset path: {name}')
        path = (directory / name).resolve()
        if not path.is_relative_to(directory) or not path.is_file() or digest(path) != checksum:
            raise ValueError(f'Missing or modified asset: {name}')
    return {'files_verified': len(checksums), 'status': 'ok'}

def package(args):
    directory = args.input.resolve()
    verify(directory)
    info = json.loads((directory / 'model.json').read_text())
    if not (directory / 'LICENSE.md').is_file() or not info.get('license_id'):
        raise ValueError('Release packaging requires LICENSE.md and model.json license_id')
    if not (directory / 'provenance.json').is_file(): raise ValueError('Release packaging requires provenance.json')
    if args.output.exists(): raise ValueError('Archive already exists')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    checksums = json.loads((directory / 'checksums.json').read_text())
    if not {'model.json', 'provenance.json', 'LICENSE.md'}.issubset(checksums):
        raise ValueError('Release metadata must be covered by checksums.json')
    with tempfile.TemporaryDirectory(prefix='.sbv2-package-', dir=args.output.parent) as temporary:
        staging = Path(temporary) / args.output.name
        with tarfile.open(staging, 'w:gz', compresslevel=1) as archive:
            for name in sorted([*checksums, 'checksums.json']):
                path = directory / name
                if path.is_symlink() or not path.is_file(): raise ValueError(f'Invalid release asset: {name}')
                item = archive.gettarinfo(str(path), arcname=f'{directory.name}/{name}')
                item.uid = item.gid = 0; item.uname = item.gname = ''; item.mtime = 0; item.mode = 0o644
                with path.open('rb') as stream: archive.addfile(item, stream)
        staging.rename(args.output)
    write_json(args.output.with_suffix(args.output.suffix + '.json'),
        {'file': args.output.name, 'sha256': digest(args.output), 'bytes': args.output.stat().st_size, 'model': info})
    print(args.output)

def doctor(_):
    results = {'python': sys.version.split()[0], 'platform': platform.platform(), 'machine': platform.machine(), 'packages': {}}
    for name in ['coremltools','torch','numpy','safetensors','transformers','pydantic']:
        try: results['packages'][name] = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError: results['packages'][name] = 'missing'
    results['macos_conversion_available'] = platform.system() == 'Darwin' and all(v != 'missing' for v in results['packages'].values())
    print(json.dumps(results, indent=2))

def build_bert(args):
    source = args.checkpoint_dir.resolve()
    if platform.system() != 'Darwin': raise ValueError('BERT conversion requires macOS')
    if args.output.exists(): raise ValueError('Output already exists')
    for name in ('config.json', 'vocab.txt'):
        if not (source / name).is_file(): raise ValueError(f'Missing {name}')
    config = json.loads((source / 'config.json').read_text())
    if (config.get('model_type'), config.get('hidden_size'), config.get('num_hidden_layers')) != ('deberta-v2', 1024, 24):
        raise ValueError('Expected ku-nlp/deberta-v2-large-japanese-char-wwm')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.sbv2-bert-', dir=args.output.parent) as temporary:
        result = Path(temporary) / 'bert'
        worker('sbv2_coreml._conversion.build_coreml_bert_blocks_from_hf', source,
            '--output-dir', result / 'coreml_blocks', '--block', 'prefix.0', '--block', 'group.1-23-conv',
            '--seq-len-min', 64, '--seq-len-max', 256, '--seq-len-example', 64,
            '--seq-len-candidates', '64,128,256', '--local-files-only', '--compute-precision', 'float32')
        manifest = result / 'coreml_blocks/coreml_bert_blocks_manifest.json'
        content = json.loads(manifest.read_text())
        for block in content['blocks']: block['mlpackage'] = Path(block['mlpackage']).name
        write_json(manifest, content)
        shutil.copy2(source / 'vocab.txt', result / 'vocab.txt')
        write_json(result / 'provenance.json', {'source': 'https://huggingface.co/ku-nlp/deberta-v2-large-japanese-char-wwm',
            'converter_version': __version__, 'inputs': {p.name: digest(p) for p in source.iterdir() if p.is_file() and p.suffix in ('.json','.txt','.safetensors','.bin')}})
        result.rename(args.output)
    print(f'BERT ready: {args.output}')

def compress_common(args):
    if platform.system() != 'Darwin': raise ValueError('Model compression requires macOS')
    source = args.input.resolve(); destination = args.output.resolve()
    if destination.exists(): raise ValueError('Output already exists; choose a new directory')
    if destination.is_relative_to(source): raise ValueError('Output must be outside the input directory')
    verify(source)
    info = json.loads((source / 'model.json').read_text())
    if info.get('kind') != 'common' or info.get('shared_bert') != 'deberta-v2-large-japanese-char-wwm-coreml-v1':
        raise ValueError('Expected the shared SBV2 Core ML common model')
    checksums = json.loads((source / 'checksums.json').read_text())
    if not {'model.json', 'provenance.json', 'LICENSE.md'}.issubset(checksums):
        raise ValueError('Input license and provenance must be covered by checksums.json')
    if info.get('bert_directory') != 'bert' or info.get('dictionary_directory') != 'dictionary':
        raise ValueError('Expected bert and dictionary directories')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.sbv2-compress-', dir=destination.parent) as temporary:
        result = Path(temporary) / destination.name; result.mkdir()
        for name in checksums:
            if name.startswith('bert/') or name in ('model.json', 'provenance.json', 'download.json'):
                continue
            # Compiled platform caches are never part of portable model bundles.
            if any(part.endswith('.mlmodelc') for part in Path(name).parts): continue
            if name in ('README.md', 'README.en.md'): name_out = 'source-model-card' + ('.en.md' if name == 'README.en.md' else '.md')
            else: name_out = name
            path = result / name_out; path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source / name, path)
        worker('sbv2_coreml.compression', '--input', source / 'bert', '--output', result / 'bert', '--mode', args.mode)
        info.update(name=destination.name, bert_weight_storage=args.mode, bert_compute_precision='float32')
        write_json(result / 'model.json', info)
        provenance = json.loads((source / 'provenance.json').read_text())
        provenance['weight_compression'] = {'component': 'bert', 'mode': args.mode,
            'source_checksums_sha256': digest(source / 'checksums.json'), 'converter_version': __version__,
            'compute_precision': 'float32', 'voice_weights_changed': False}
        if 'conversion' in provenance: provenance['source_conversion'] = provenance.pop('conversion')
        provenance['conversion'] = 'BERT weight storage compression; FP32 computation retained'
        write_json(result / 'provenance.json', provenance)
        mode_label = '8bit / block 32' if args.mode == 'int8' else 'FP16 weight storage'
        write_json(result / 'compression.json', {'component': 'bert', 'mode': args.mode,
            'compute_precision': 'float32', 'perceptual_quality_validated': False})
        (result / 'README.md').write_text(f'''[English](README.en.md)

# {destination.name}

Style-Bert-VITS2 JP-Extra SDK用の共通BERT・日本語辞書です。
BERTの重みを{mode_label}で保存し、計算はFP32を維持します。声モデルは別途用意してください。

サンプルアプリの「モデル設定」で、このフォルダをBERTとして選択すると辞書も設定されます。
SDKには`bert`、`dictionary`と、別の声モデルフォルダを渡します。

圧縮前とは数値が変わります。採用前に、使う声・文章・端末で音質と速度を確認してください。
元モデルの出典・利用条件は`LICENSE.md`、`provenance.json`、`source-model-card.md`を参照してください。
辞書の利用条件は`dictionary/COPYING`にあります。
''', encoding='utf-8')
        (result / 'README.en.md').write_text(f'''[日本語](README.md)

# {destination.name}

Shared BERT and Japanese dictionary for the Style-Bert-VITS2 JP-Extra SDK.
BERT weights use {mode_label}; computation remains FP32. Supply a separate voice model.

Select this folder as BERT in the sample app's model settings. The dictionary is detected automatically.
For the SDK, pass the `bert` and `dictionary` subfolders alongside your voice folder.

Compression changes numerical results. Check audio quality and speed with your voices, texts and devices before adoption.
See `LICENSE.md`, `provenance.json`, `source-model-card.en.md` and `dictionary/COPYING` for attribution and terms.
''', encoding='utf-8')
        files = sorted(p for p in result.rglob('*') if p.is_file())
        write_json(result / 'checksums.json', {str(p.relative_to(result)): digest(p) for p in files})
        write_json(result / 'download.json', {'formatVersion': 1, 'name': destination.name,
            'files': [{'path': str(p.relative_to(result)), 'sha256': digest(p), 'bytes': p.stat().st_size}
                      for p in [*files, result / 'checksums.json']]})
        verify(result)
        result.rename(destination)
    print(f'Compressed common model ready: {destination}')

def main():
    parser = argparse.ArgumentParser(description='Convert JP-Extra voices for iPhone and Apple Silicon Mac')
    parser.add_argument('--version', action='version', version=__version__)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('doctor').set_defaults(run=doctor)
    bert = commands.add_parser('build-bert', help='Rebuild the shared BERT from a local HF checkpoint')
    bert.add_argument('--checkpoint-dir', type=Path, required=True)
    bert.add_argument('--output', type=Path, required=True); bert.set_defaults(run=build_bert)
    compress = commands.add_parser('compress-common', help='Compress shared BERT weights; keep voice models separate')
    compress.add_argument('--input', type=Path, required=True)
    compress.add_argument('--output', type=Path, required=True)
    compress.add_argument('--mode', choices=['int8', 'fp16-weights'], default='int8')
    compress.set_defaults(run=compress_common)
    inspect = commands.add_parser('inspect-hub', help='Inspect available original weights and license without downloading weights')
    inspect.add_argument('url'); inspect.set_defaults(run=lambda args: print(json.dumps(aivis_metadata(args.url)[2], indent=2, ensure_ascii=False)))
    convert_parser = commands.add_parser('convert')
    inputs = convert_parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument('--aivis-url'); inputs.add_argument('--aivm', type=Path); inputs.add_argument('--checkpoint', type=Path)
    for name in ['config', 'styles', 'source-root', 'license-file']: convert_parser.add_argument('--' + name, type=Path)
    for name in ['name', 'source-url', 'license-id']: convert_parser.add_argument('--' + name)
    convert_parser.add_argument('--cache', type=Path, default=Path.home() / 'Library/Caches/sbv2-coreml-converter')
    convert_parser.add_argument('--output', type=Path, required=True); convert_parser.set_defaults(run=convert)
    validate = commands.add_parser('verify'); validate.add_argument('directory', type=Path)
    validate.set_defaults(run=lambda args: print(json.dumps(verify(args.directory))))
    pack = commands.add_parser('package'); pack.add_argument('--input', type=Path, required=True)
    pack.add_argument('--output', type=Path, required=True); pack.set_defaults(run=package)
    args = parser.parse_args()
    try: args.run(args)
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error: parser.exit(1, f'Error: {error}\n')

if __name__ == '__main__': main()
