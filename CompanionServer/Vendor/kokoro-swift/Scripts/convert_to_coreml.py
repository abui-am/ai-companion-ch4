#!/usr/bin/env python3
"""Convert Kokoro-82M to CoreML ML Program packages.

This exporter produces two variants:

* ``kokoro_ane.mlpackage``
    Fixed-token / fixed-frame export intended for ANE-friendly deployment.
* ``kokoro_cpu.mlpackage``
    Flexible-token / fixed-frame export intended for CPU-only deployment.

Notes
-----
The original Kokoro model uses packed sequences, stochastic source generation,
and data-dependent alignment construction. ``coreml_wrapper.py`` replaces those
export blockers without modifying the original Python sources.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import time
from pathlib import Path
from typing import Iterable, Sequence

import coremltools as ct
import numpy as np
import torch

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from coreml_wrapper import (  # noqa: E402
    DEFAULT_MAX_FRAMES,
    DEFAULT_MAX_TOKENS,
    KokoroCoreMLANEWrapper,
    KokoroCoreMLCPUWrapper,
    load_kmodel,
)

REPO_ROOT = SCRIPT_DIR.parents[2]
DEFAULT_CONFIG = REPO_ROOT / "Kokoro-82M" / "config.json"
DEFAULT_CHECKPOINT = REPO_ROOT / "Kokoro-82M" / "kokoro-v1_0.pth"
DEFAULT_ANE_OUTPUT_DIR = REPO_ROOT / "CoreML_ANE"
DEFAULT_CPU_OUTPUT_DIR = REPO_ROOT / "CoreML_CPU"
DEFAULT_ANE_OUTPUT = DEFAULT_ANE_OUTPUT_DIR / "kokoro_ane.mlpackage"
DEFAULT_CPU_OUTPUT = DEFAULT_CPU_OUTPUT_DIR / "kokoro_cpu.mlpackage"
DEFAULT_DEPLOYMENT_TARGET = "macOS14"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    parser.add_argument("--ane-output-dir", type=Path, default=DEFAULT_ANE_OUTPUT_DIR)
    parser.add_argument("--cpu-output-dir", type=Path, default=DEFAULT_CPU_OUTPUT_DIR)
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    parser.add_argument(
        "--max-frames",
        type=int,
        default=DEFAULT_MAX_FRAMES,
        help="Fixed frame bucket for exported audio. Raise this for longer utterances; lower it for smaller CoreML packages.",
    )
    parser.add_argument(
        "--minimum-deployment-target",
        default=DEFAULT_DEPLOYMENT_TARGET,
        help="coremltools target enum name, for example macOS14 or iOS17",
    )
    parser.add_argument(
        "--skip-verify",
        action="store_true",
        help="Skip post-conversion CoreML load/predict checks.",
    )
    return parser.parse_args()



def resolve_target(name: str):
    if not hasattr(ct.target, name):
        valid = [entry for entry in dir(ct.target) if not entry.startswith("_")]
        raise ValueError(f"Unknown CoreML deployment target {name!r}. Available: {valid}")
    return getattr(ct.target, name)



def build_example_ane_inputs(max_tokens: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
    active_tokens = min(64, max_tokens)
    input_ids = torch.zeros((1, max_tokens), dtype=torch.int32)
    input_ids[0, :active_tokens] = (torch.arange(active_tokens, dtype=torch.int32) % 32) + 1
    input_lengths = torch.tensor([active_tokens], dtype=torch.int32)
    ref_s = torch.randn((1, 256), dtype=torch.float16)
    speed = torch.tensor([1.0], dtype=torch.float32)
    return input_ids, input_lengths, ref_s, speed



def build_example_cpu_inputs(example_tokens: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
    input_ids = (torch.arange(example_tokens, dtype=torch.int32).unsqueeze(0) % 32) + 1
    input_lengths = torch.tensor([example_tokens], dtype=torch.int32)
    ref_s = torch.randn((1, 256), dtype=torch.float32)
    speed = torch.tensor([1.0], dtype=torch.float32)
    return input_ids, input_lengths, ref_s, speed



def summarize_tensors(label: str, outputs: Sequence[torch.Tensor]) -> None:
    print(label)
    for index, tensor in enumerate(outputs):
        print(f"  output[{index}] shape={tuple(tensor.shape)} dtype={tensor.dtype}")



def run_torch_smoke(model: torch.nn.Module, inputs: Sequence[torch.Tensor], label: str) -> None:
    with torch.no_grad():
        started = time.perf_counter()
        outputs = model(*inputs)
        elapsed_ms = (time.perf_counter() - started) * 1000.0
    summarize_tensors(f"{label} PyTorch smoke ({elapsed_ms:.1f} ms)", outputs)



def trace_module(module: torch.nn.Module, example_inputs: Sequence[torch.Tensor]) -> torch.jit.ScriptModule:
    module.eval()
    with torch.no_grad():
        return torch.jit.trace(module, tuple(example_inputs), strict=False, check_trace=False)



def convert_ane_model(
    traced: torch.jit.ScriptModule,
    output_path: Path,
    *,
    max_tokens: int,
    deployment_target,
):
    started = time.perf_counter()
    model = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=deployment_target,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, max_tokens), dtype=np.int32),
            ct.TensorType(name="input_lengths", shape=(1,), dtype=np.int32),
            ct.TensorType(name="ref_s", shape=(1, 256), dtype=np.float16),
            ct.TensorType(name="speed", shape=(1,), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="audio"),
            ct.TensorType(name="pred_dur"),
        ],
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        shutil.rmtree(output_path)
    model.save(str(output_path))
    elapsed = time.perf_counter() - started
    print(f"Saved ANE model to {output_path} ({elapsed:.1f}s)")
    return model



def convert_cpu_model(
    traced: torch.jit.ScriptModule,
    output_path: Path,
    *,
    max_tokens: int,
    deployment_target,
):
    started = time.perf_counter()
    token_dim = ct.RangeDim(lower_bound=1, upper_bound=max_tokens, default=min(128, max_tokens))
    model = ct.convert(
        traced,
        convert_to="mlprogram",
        minimum_deployment_target=deployment_target,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        compute_precision=ct.precision.FLOAT32,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, token_dim), dtype=np.int32),
            ct.TensorType(name="input_lengths", shape=(1,), dtype=np.int32),
            ct.TensorType(name="ref_s", shape=(1, 256), dtype=np.float32),
            ct.TensorType(name="speed", shape=(1,), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="audio"),
            ct.TensorType(name="pred_dur"),
        ],
    )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        shutil.rmtree(output_path)
    model.save(str(output_path))
    elapsed = time.perf_counter() - started
    print(f"Saved CPU model to {output_path} ({elapsed:.1f}s)")
    return model



def _to_numpy_dict(entries: Iterable[tuple[str, np.ndarray]]) -> dict[str, np.ndarray]:
    return {name: value for name, value in entries}



def verify_model(package_path: Path, inputs: dict[str, np.ndarray], *, compute_units: ct.ComputeUnit) -> None:
    started = time.perf_counter()
    model = ct.models.MLModel(str(package_path), compute_units=compute_units)
    load_ms = (time.perf_counter() - started) * 1000.0

    started = time.perf_counter()
    outputs = model.predict(inputs)
    predict_ms = (time.perf_counter() - started) * 1000.0

    print(f"Verified {package_path.name}: load={load_ms:.1f} ms predict={predict_ms:.1f} ms")
    for key, value in outputs.items():
        array = np.asarray(value)
        print(f"  {key}: shape={array.shape} dtype={array.dtype}")



def main() -> None:
    args = parse_args()
    deployment_target = resolve_target(args.minimum_deployment_target)

    print("Loading Kokoro checkpoint...")
    kmodel = load_kmodel(
        REPO_ROOT,
        args.config,
        args.checkpoint,
        disable_complex=True,
    )

    ane_wrapper = KokoroCoreMLANEWrapper(
        kmodel,
        max_tokens=args.max_tokens,
        max_frames=args.max_frames,
    ).eval()
    cpu_wrapper = KokoroCoreMLCPUWrapper(
        kmodel,
        max_tokens=args.max_tokens,
        max_frames=args.max_frames,
    ).eval()

    ane_inputs = build_example_ane_inputs(args.max_tokens)
    cpu_inputs = build_example_cpu_inputs(min(128, args.max_tokens))

    run_torch_smoke(ane_wrapper, ane_inputs, "ANE wrapper")
    run_torch_smoke(cpu_wrapper, cpu_inputs, "CPU wrapper")

    print("Tracing ANE wrapper...")
    traced_ane = trace_module(ane_wrapper, ane_inputs)
    print("Tracing CPU wrapper...")
    traced_cpu = trace_module(cpu_wrapper, cpu_inputs)

    ane_output = args.ane_output_dir / DEFAULT_ANE_OUTPUT.name
    cpu_output = args.cpu_output_dir / DEFAULT_CPU_OUTPUT.name

    convert_ane_model(
        traced_ane,
        ane_output,
        max_tokens=args.max_tokens,
        deployment_target=deployment_target,
    )
    convert_cpu_model(
        traced_cpu,
        cpu_output,
        max_tokens=args.max_tokens,
        deployment_target=deployment_target,
    )

    if args.skip_verify:
        return

    ane_verify_inputs = _to_numpy_dict(
        [
            ("input_ids", np.asarray(ane_inputs[0].cpu().numpy(), dtype=np.int32)),
            ("input_lengths", np.asarray(ane_inputs[1].cpu().numpy(), dtype=np.int32)),
            ("ref_s", np.asarray(ane_inputs[2].cpu().numpy(), dtype=np.float16)),
            ("speed", np.asarray(ane_inputs[3].cpu().numpy(), dtype=np.float32)),
        ]
    )
    cpu_verify_inputs = _to_numpy_dict(
        [
            ("input_ids", np.asarray(cpu_inputs[0].cpu().numpy(), dtype=np.int32)),
            ("input_lengths", np.asarray(cpu_inputs[1].cpu().numpy(), dtype=np.int32)),
            ("ref_s", np.asarray(cpu_inputs[2].cpu().numpy(), dtype=np.float32)),
            ("speed", np.asarray(cpu_inputs[3].cpu().numpy(), dtype=np.float32)),
        ]
    )

    verify_model(ane_output, ane_verify_inputs, compute_units=ct.ComputeUnit.ALL)
    verify_model(cpu_output, cpu_verify_inputs, compute_units=ct.ComputeUnit.CPU_ONLY)


if __name__ == "__main__":
    main()
