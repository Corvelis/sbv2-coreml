import io
import json
import tarfile
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from unittest.mock import patch
from sbv2_coreml.assets import aivis_metadata, safe_extract, digest, write_json, prepare_upstream
from sbv2_coreml.cli import verify, build_bert

class AssetsTests(unittest.TestCase):
    def test_aivmx_only_rejected_before_download(self):
        with patch('sbv2_coreml.assets.request_json', return_value={'model_files': [{'model_type': 'AIVMX'}]}):
            with self.assertRaisesRegex(ValueError, 'AIVMX alone'):
                aivis_metadata('https://hub.aivis-project.com/aivm-models/a670e6b8-0852-45b2-8704-1bc9862f2fe6')

    def test_wrong_hub_host_rejected(self):
        with self.assertRaises(ValueError): aivis_metadata('https://example.org/aivm-models/a670e6b8-0852-45b2-8704-1bc9862f2fe6')

    def test_tar_traversal_and_link_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            for name, link in [('../escape',False), ('symlink',True)]:
                path=root/'bad.tar'
                with tarfile.open(path,'w') as archive:
                    member=tarfile.TarInfo(name)
                    if link: member.type=tarfile.SYMTYPE;member.linkname='../escape'
                    else: member.size=1
                    archive.addfile(member,None if link else io.BytesIO(b'x'))
                with self.assertRaises(ValueError): safe_extract(path,root/'output')
                self.assertFalse((root/'escape').exists())

    def test_hash_detects_modified_weight(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); weight=root/'weight.bin';weight.write_bytes(b'original')
            write_json(root/'checksums.json',{'weight.bin':digest(weight)})
            self.assertEqual(verify(root)['status'],'ok')
            weight.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'modified'): verify(root)

    def test_checksum_path_cannot_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary);(root/'nested').mkdir();(root/'outside').write_bytes(b'x')
            write_json(root/'nested/checksums.json',{'../outside':digest(root/'outside')})
            with self.assertRaises(ValueError): verify(root/'nested')

    def test_source_compatibility_does_not_import_ort_or_change_original(self):
        import runpy
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root/'source'; target = source/'style_bert_vits2/utils/__init__.py'
            target.parent.mkdir(parents=True)
            original = '\nimport onnxruntime\ndef options(x: onnxruntime.InferenceSession):\n    """Optional helper."""\n    # ONNX セッションに対応する SessionOptions を取得\n    return onnxruntime.RunOptions()\n'
            target.write_text(original)
            prepare_upstream(source, root/'prepared')
            runpy.run_path(str(root/'prepared/style_bert_vits2/utils/__init__.py'))
            self.assertEqual(target.read_text(), original)

    def test_bert_manifest_remains_portable_after_temporary_output_moves(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root/'checkpoint'; source.mkdir()
            write_json(source/'config.json', {'model_type':'deberta-v2','hidden_size':1024,'num_hidden_layers':24})
            (source/'vocab.txt').write_text('[PAD]\n')
            def fake_worker(*args):
                output = Path(args[args.index('--output-dir') + 1]); output.mkdir(parents=True)
                write_json(output/'coreml_bert_blocks_manifest.json', {'blocks':[{'mlpackage':str(output/'prefix.0_enum.mlpackage')}]})
            with patch('sbv2_coreml.cli.worker', side_effect=fake_worker), patch('sbv2_coreml.cli.platform.system', return_value='Darwin'):
                build_bert(Namespace(checkpoint_dir=source, output=root/'result'))
            result = json.loads((root/'result/coreml_blocks/coreml_bert_blocks_manifest.json').read_text())
            self.assertEqual(result['blocks'][0]['mlpackage'], 'prefix.0_enum.mlpackage')

if __name__ == '__main__': unittest.main()
