"""Small real Core ML regression test; optional conversion dependencies are required."""
import importlib.util
import platform
import tempfile
import unittest
from pathlib import Path


@unittest.skipUnless(platform.system() == 'Darwin' and importlib.util.find_spec('coremltools'),
                     'Requires macOS and the convert dependencies')
class CompressionModelTests(unittest.TestCase):
    def test_compressed_storage_retains_float32_interface_and_cpu_prediction(self):
        import coremltools as ct
        import numpy as np
        from coremltools.converters.mil import Builder as mb
        from sbv2_coreml.compression import compress_model

        rng = np.random.default_rng(42)
        weights = rng.normal(0, 0.03, (256, 128)).astype(np.float32)
        inputs = rng.normal(size=(1, 128)).astype(np.float32)

        @mb.program(input_specs=[mb.TensorSpec(shape=(1, 128))], opset_version=ct.target.iOS18)
        def program(x):
            return mb.linear(x=x, weight=weights, bias=np.zeros(256, dtype=np.float32))

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); source = root / 'source.mlpackage'
            ct.convert(program, minimum_deployment_target=ct.target.iOS18,
                       compute_precision=ct.precision.FLOAT32, skip_model_load=True).save(str(source))
            reference = ct.models.MLModel(str(source), compute_units=ct.ComputeUnit.CPU_ONLY)
            expected = next(iter(reference.predict({'x': inputs}).values()))
            size = lambda p: sum(f.stat().st_size for f in (p / 'Data/com.apple.CoreML/weights').rglob('*') if f.is_file())
            for mode in ('int8', 'fp16-weights'):
                with self.subTest(mode=mode):
                    target = root / (mode + '.mlpackage')
                    unloaded = ct.models.MLModel(str(source), skip_model_load=True)
                    compact = compress_model(unloaded, mode); compact.save(str(target))
                    runtime = ct.models.MLModel(str(target), compute_units=ct.ComputeUnit.CPU_ONLY)
                    actual = next(iter(runtime.predict({'x': inputs}).values()))
                    self.assertEqual(actual.dtype, np.float32)
                    self.assertEqual(actual.shape, expected.shape)
                    self.assertTrue(np.isfinite(actual).all())
                    relative = np.linalg.norm(actual - expected) / np.linalg.norm(expected)
                    self.assertLess(relative, 0.02 if mode == 'int8' else 0.001)
                    self.assertLess(size(target), size(source) * 0.8)
                    spec = runtime.get_spec()
                    for feature in [*spec.description.input, *spec.description.output]:
                        self.assertEqual(feature.type.multiArrayType.dataType,
                                         ct.proto.FeatureTypes_pb2.ArrayFeatureType.FLOAT32)


if __name__ == '__main__':
    unittest.main()
