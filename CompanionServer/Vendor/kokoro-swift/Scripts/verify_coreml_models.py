#!/usr/bin/env python3
"""Load and run dummy inference for exported Kokoro CoreML packages."""

from __future__ import annotations

import argparse
from pathlib import Path

import coremltools as ct
import numpy as np

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parents[2]
DEFAULT_ROOT = REPO_ROOT


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root-dir", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--max-tokens", type=int, default=512)
    parser.add_argument("--cpu-tokens", type=int, default=128)
    return parser.parse_args()



def describe_outputs(label: str, outputs: dict[str, object]) -> None:
    print(label)
    for key, value in outputs.items():
        array = np.asarray(value)
        print(f"  {key}: shape={array.shape} dtype={array.dtype}")



def main() -> None:
    args = parse_args()

    ane_path = args.root_dir / "CoreML_ANE" / "kokoro_ane.mlpackage"
    cpu_path = args.root_dir / "CoreML_CPU" / "kokoro_cpu.mlpackage"
    cpu_tokens = min(args.cpu_tokens, args.max_tokens)

    ane_model = ct.models.MLModel(str(ane_path), compute_units=ct.ComputeUnit.ALL)
    cpu_model = ct.models.MLModel(str(cpu_path), compute_units=ct.ComputeUnit.CPU_ONLY)

    ane_inputs = {
        "input_ids": np.pad(
            ((np.arange(min(64, args.max_tokens), dtype=np.int32) % 32) + 1)[None, :],
            ((0, 0), (0, max(0, args.max_tokens - min(64, args.max_tokens)))),
            constant_values=0,
        ),
        "input_lengths": np.asarray([min(64, args.max_tokens)], dtype=np.int32),
        "ref_s": np.random.randn(1, 256).astype(np.float16),
        "speed": np.asarray([1.0], dtype=np.float32),
    }
    cpu_inputs = {
        "input_ids": ((np.arange(cpu_tokens, dtype=np.int32) % 32) + 1)[None, :],
        "input_lengths": np.asarray([cpu_tokens], dtype=np.int32),
        "ref_s": np.random.randn(1, 256).astype(np.float32),
        "speed": np.asarray([1.0], dtype=np.float32),
    }

    describe_outputs("ANE prediction", ane_model.predict(ane_inputs))
    describe_outputs("CPU prediction", cpu_model.predict(cpu_inputs))


if __name__ == "__main__":
    main()
