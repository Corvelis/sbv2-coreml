#!/usr/bin/env python3
"""Compare native 13-frame context/tail correction against the full FP32 decoder.

Run with the conversion Python environment on an Apple Silicon Mac. This is a
numerical regression check, not a substitute for listening to natural speech.
"""
import argparse
import json
from pathlib import Path
import coremltools as ct
import numpy as np


def error(reference, actual):
    difference = reference.astype(np.float64) - actual.astype(np.float64)
    mse = np.mean(difference ** 2)
    return dict(max_abs=float(np.max(np.abs(difference))), rmse=float(np.sqrt(mse)),
                snr_db=float(10 * np.log10(np.mean(reference.astype(np.float64) ** 2) / mse)) if mse else 300.0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--voice', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    package = args.voice / 'coreml_voice/voice_shared.mlpackage'
    reference = ct.models.MLModel(str(package), function_name='decoder_combined_flex', compute_units=ct.ComputeUnit.CPU_ONLY)
    speakers = sorted(set(json.loads((args.voice/'config.json').read_text())['data']['spk2id'].values()))
    def predict(model, z, speaker):
        return model.predict({'_Mul_9_output_0': z, 'sid': np.array([speaker], np.int32)})['output'].reshape(-1)
    records = []
    for units in (ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.CPU_AND_NE):
        main_decoder = ct.models.MLModel(str(package), function_name='decoder_combined_len_256_fp16', compute_units=units)
        tail_decoder = ct.models.MLModel(str(package), function_name='decoder_combined_len_32_fp16', compute_units=units)
        flex_decoder = ct.models.MLModel(str(package), function_name='decoder_combined_flex', compute_units=units)
        rng = np.random.default_rng(20260928)
        for frames in (16, 31, 64, 236, 512):
            for speaker in speakers:
                z = (rng.standard_normal((1, 192, frames)) * .2).astype(np.float32)
                expected = predict(reference, z, speaker)
                chunks = []
                for start in range(0, frames, 230):
                    end = min(start + 230, frames)
                    left, right = max(0, start - 13), min(frames, end + 13)
                    if right - left < 16: left = max(0, right - 16)
                    window = np.zeros((1, 192, 256), np.float32)
                    window[:, :, :right-left] = z[:, :, left:right]
                    wave = predict(main_decoder, window, speaker)
                    chunks.append(wave[(start-left)*512:(end-left)*512])
                actual = np.concatenate(chunks)
                tail_frames = min(frames, 32)
                tail = predict(tail_decoder if tail_frames == 32 else flex_decoder, z[:, :, -tail_frames:], speaker)
                actual[-13*512:] = tail[-13*512:]
                if not np.isfinite(actual).all(): raise ValueError('Non-finite output')
                metrics = error(expected, actual)
                seams = []
                for boundary in range(230, frames, 230):
                    span = slice((boundary-1)*512, (boundary+1)*512)
                    seams.append({'frame': boundary, **error(expected[span], actual[span])})
                records.append({'compute_units': units.name, 'frames': frames, 'speaker': speaker,
                                **metrics, 'seams': seams})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({'reference': 'Full FP32 CPU decoder', 'context_frames':13, 'runs':records}, indent=2)+'\n')
    # This guard detects gross conversion/windowing regressions. Perceptual review remains separate.
    if any(r['snr_db'] < 30 or r['max_abs'] > .05 for r in records):
        raise ValueError('Decoder window regression; inspect the recorded report')
    print(f'Decoder windows verified: {len(records)} cases; minimum SNR {min(r["snr_db"] for r in records):.2f} dB')


if __name__ == '__main__': main()
