import json
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch

from sbv2_coreml.assets import digest, write_json
from sbv2_coreml.cli import compress_common, verify


class CompressionBundleTests(unittest.TestCase):
    def setUp(self):
        # These tests mock the Core ML worker and exercise portable packaging.
        # Actual model conversion is tested separately on macOS.
        platform = patch('sbv2_coreml.cli.platform.system', return_value='Darwin')
        platform.start()
        self.addCleanup(platform.stop)

    def source(self, root):
        source = root / 'common'; source.mkdir()
        (source / 'bert').mkdir(); (source / 'dictionary').mkdir()
        (source / 'bert/vocab.txt').write_text('original vocabulary')
        (source / 'dictionary/sys.dic').write_bytes(b'unchanged dictionary')
        (source / 'dictionary/COPYING').write_text('dictionary notice')
        (source / 'LICENSE.md').write_text('model attribution and license')
        (source / 'README.md').write_text('original model card')
        (source / 'README.en.md').write_text('original English card')
        write_json(source / 'provenance.json', {'bert': {'repository': 'example/bert'}, 'conversion': 'original'})
        write_json(source / 'model.json', {'kind': 'common',
            'shared_bert': 'deberta-v2-large-japanese-char-wwm-coreml-v1',
            'bert_directory': 'bert', 'dictionary_directory': 'dictionary', 'license_id': 'cc-by-sa-4.0'})
        write_json(source / 'checksums.json', {str(p.relative_to(source)): digest(p)
            for p in source.rglob('*') if p.is_file()})
        # Runtime caches outside the checksum manifest must not enter the new bundle.
        cache = source / 'bert/cache.mlmodelc'; cache.mkdir(); (cache / 'runtime.bin').write_bytes(b'platform cache')
        return source

    @staticmethod
    def fake_worker(script, *args):
        args = list(args); target = Path(args[args.index('--output') + 1]); target.mkdir()
        (target / 'vocab.txt').write_text('original vocabulary')
        (target / 'weight.bin').write_bytes(b'compressed test weights')
        write_json(target / 'compression_report.json', {'mode': args[args.index('--mode') + 1]})

    def test_portable_bundle_preserves_terms_and_regenerates_all_download_hashes(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = self.source(root); destination = root / 'compact'
            before = {str(p.relative_to(source)): digest(p) for p in source.rglob('*') if p.is_file()}
            with patch('sbv2_coreml.cli.worker', self.fake_worker):
                compress_common(Namespace(input=source, output=destination, mode='int8'))
            self.assertEqual(verify(destination)['status'], 'ok')
            for name in ('LICENSE.md', 'dictionary/COPYING', 'dictionary/sys.dic'):
                self.assertEqual((destination / name).read_bytes(), (source / name).read_bytes())
            self.assertFalse(list(destination.rglob('*.mlmodelc')))
            self.assertEqual((destination / 'source-model-card.md').read_text(), 'original model card')
            download = json.loads((destination / 'download.json').read_text())
            for item in download['files']:
                asset = destination / item['path']
                self.assertEqual(digest(asset), item['sha256'])
                self.assertEqual(asset.stat().st_size, item['bytes'])
            self.assertEqual(before, {str(p.relative_to(source)): digest(p) for p in source.rglob('*') if p.is_file()})
            provenance = json.loads((destination / 'provenance.json').read_text())
            self.assertEqual(provenance['bert']['repository'], 'example/bert')
            self.assertEqual(provenance['source_conversion'], 'original')

    def test_corrupted_source_is_rejected_without_output_or_conversion(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = self.source(root); (source / 'dictionary/sys.dic').write_bytes(b'corrupt')
            with patch('sbv2_coreml.cli.worker') as worker:
                with self.assertRaisesRegex(ValueError, 'modified'):
                    compress_common(Namespace(input=source, output=root / 'compact', mode='int8'))
                worker.assert_not_called()
            self.assertFalse((root / 'compact').exists())

    def test_failed_conversion_cannot_replace_or_leave_partial_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = self.source(root); destination = root / 'compact'
            with patch('sbv2_coreml.cli.worker', side_effect=ValueError('conversion failed')):
                with self.assertRaisesRegex(ValueError, 'conversion failed'):
                    compress_common(Namespace(input=source, output=destination, mode='int8'))
            self.assertFalse(destination.exists())
            self.assertFalse(list(root.glob('.sbv2-compress-*')))
            with self.assertRaisesRegex(ValueError, 'outside'):
                compress_common(Namespace(input=source, output=source / 'compact', mode='int8'))


if __name__ == '__main__':
    unittest.main()
