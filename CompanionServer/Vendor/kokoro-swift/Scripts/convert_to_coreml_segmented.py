#!/usr/bin/env python3
"""Export Kokoro-82M as segmented CoreML packages plus an optional v2 monolith.

This script leaves the existing monolithic exporter untouched and adds two new
capabilities:

1. Attempt a v2 monolithic export that preserves recurrent structure as real
   ``aten::lstm`` / MIL ``lstm`` ops where possible.
2. Export four segment models that follow the ``forward_with_tokens`` dataflow
   more closely and allow CPU-only execution for the LSTM-heavy stages.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import time
from collections import Counter
from pathlib import Path
from typing import Iterable, Mapping, Sequence

import coremltools as ct
import numpy as np
import torch

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from coreml_wrapper import DEFAULT_MAX_FRAMES, DEFAULT_MAX_TOKENS, load_kmodel  # noqa: E402
from coreml_wrapper_v2 import (  # noqa: E402
    AlbertEncoderSegment,
    DecoderSegment,
    KokoroCoreMLANEWrapperV2,
    ProsodyPredictorSegment,
    TextEncoderSegment,
)

REPO_ROOT = SCRIPT_DIR.parents[2]
DEFAULT_CONFIG = REPO_ROOT / "Kokoro-82M" / "config.json"
DEFAULT_CHECKPOINT = REPO_ROOT / "Kokoro-82M" / "kokoro-v1_0.pth"
DEFAULT_OUTPUT_DIR = REPO_ROOT / "CoreML_ANE"
DEFAULT_SEGMENTED_OUTPUT_DIR = DEFAULT_OUTPUT_DIR / "segmented"
DEFAULT_MONOLITH_OUTPUT = DEFAULT_OUTPUT_DIR / "kokoro_ane_v2.mlpackage"
DEFAULT_DEPLOYMENT_TARGET = "macOS14"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--checkpoint", type=Path, default=DEFAULT_CHECKPOINT)
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    parser.add_argument("--segmented-output-dir", type=Path, default=DEFAULT_SEGMENTED_OUTPUT_DIR)
    parser.add_argument("--max-tokens", type=int, default=DEFAULT_MAX_TOKENS)
    parser.add_argument("--max-frames", type=int, default=DEFAULT_MAX_FRAMES)
    parser.add_argument(
        "--minimum-deployment-target",
        default=DEFAULT_DEPLOYMENT_TARGET,
        help="coremltools target enum name, for example macOS14 or iOS17",
    )
    parser.add_argument(
        "--skip-monolith-v2",
        action="store_true",
        help="Skip the monolithic v2 export attempt and only build segmented models.",
    )
    parser.add_argument(
        "--skip-verify",
        action="store_true",
        help="Skip post-conversion CoreML load/predict and compute-plan inspection.",
    )
    parser.add_argument(
        "--skip-op-inspection",
        action="store_true",
        help="Skip the extra milinternal conversion pass used only for op counting.",
    )
    return parser.parse_args()


def resolve_target(name: str):
    if not hasattr(ct.target, name):
        valid = [entry for entry in dir(ct.target) if not entry.startswith("_")]
        raise ValueError(f"Unknown CoreML deployment target {name!r}. Available: {valid}")
    return getattr(ct.target, name)


def build_example_inputs(max_tokens: int) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
    torch.manual_seed(0)
    active_tokens = min(64, max_tokens)
    input_ids = torch.zeros((1, max_tokens), dtype=torch.int32)
    input_ids[0, :active_tokens] = (torch.arange(active_tokens, dtype=torch.int32) % 48) + 1
    input_lengths = torch.tensor([active_tokens], dtype=torch.int32)
    attention_mask = (torch.arange(max_tokens, dtype=torch.int32).unsqueeze(0) < active_tokens).to(torch.int32)
    ref_s = torch.randn((1, 256), dtype=torch.float32)
    speed = torch.tensor([1.0], dtype=torch.float32)
    return input_ids, input_lengths, attention_mask, ref_s, speed


def summarize_tensors(label: str, outputs: Sequence[torch.Tensor]) -> None:
    print(label)
    for index, tensor in enumerate(outputs):
        print(f"  output[{index}] shape={tuple(tensor.shape)} dtype={tensor.dtype}")


def run_torch_smoke(model: torch.nn.Module, inputs: Sequence[torch.Tensor], label: str) -> Sequence[torch.Tensor]:
    with torch.no_grad():
        started = time.perf_counter()
        outputs = model(*inputs)
        elapsed_ms = (time.perf_counter() - started) * 1000.0
    if not isinstance(outputs, tuple):
        outputs = (outputs,)
    summarize_tensors(f"{label} PyTorch smoke ({elapsed_ms:.1f} ms)", outputs)
    return outputs


def graph_text(module: torch.jit.ScriptModule) -> str:
    for attribute in ("inlined_graph", "graph"):
        if hasattr(module, attribute):
            try:
                return str(getattr(module, attribute))
            except Exception:
                continue
    return repr(module)


def trace_module(module: torch.nn.Module, example_inputs: Sequence[torch.Tensor]) -> torch.jit.ScriptModule:
    module.eval()
    with torch.no_grad():
        return torch.jit.trace(module, tuple(example_inputs), strict=False, check_trace=False)


def script_or_trace_module(
    module: torch.nn.Module,
    example_inputs: Sequence[torch.Tensor],
    *,
    label: str,
    prefer_script: bool,
) -> tuple[torch.jit.ScriptModule, str]:
    if prefer_script:
        try:
            scripted = torch.jit.script(module)
            text = graph_text(scripted)
            print(f"Scripted {label}; aten::lstm={'aten::lstm' in text}")
            return scripted, "script"
        except Exception as exc:
            print(f"Script failed for {label}: {type(exc).__name__}: {exc}")
    traced = trace_module(module, example_inputs)
    text = graph_text(traced)
    print(f"Traced {label}; aten::lstm={'aten::lstm' in text}")
    return traced, "trace"


def walk_mil_ops(block, counts: Counter[str]) -> None:
    for operation in block.operations:
        op_name = getattr(operation, "op_type", type(operation).__name__)
        counts[op_name] += 1
        for nested_block in getattr(operation, "blocks", []):
            walk_mil_ops(nested_block, counts)


def inspect_mil_ops(**convert_kwargs) -> Counter[str]:
    started = time.perf_counter()
    program = ct.convert(convert_to="milinternal", **convert_kwargs)
    elapsed = time.perf_counter() - started
    counts: Counter[str] = Counter()
    walk_mil_ops(program.functions["main"], counts)
    print(f"MIL inspection finished in {elapsed:.1f}s; total ops={sum(counts.values())}")
    return counts


def print_op_summary(label: str, counts: Counter[str]) -> None:
    total = sum(counts.values())
    print(f"{label} MIL op summary: total={total}")
    for key in ("lstm", "select", "sigmoid", "tile", "concat", "transpose", "gather"):
        if counts.get(key):
            print(f"  {key}: {counts[key]}")
    top = ", ".join(f"{name}={count}" for name, count in counts.most_common(12))
    print(f"  top ops: {top}")


def save_mlpackage(model: ct.models.MLModel, output_path: Path) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    if output_path.exists():
        shutil.rmtree(output_path)
    model.save(str(output_path))


def convert_mlprogram(
    *,
    label: str,
    module: torch.jit.ScriptModule,
    output_path: Path,
    minimum_deployment_target,
    compute_units: ct.ComputeUnit,
    compute_precision,
    inputs: Sequence[ct.TensorType],
    outputs: Sequence[ct.TensorType],
    inspect_ops: bool,
) -> tuple[ct.models.MLModel, Counter[str]]:
    op_counts: Counter[str] = Counter()
    if inspect_ops:
        inspect_kwargs = dict(
            model=module,
            minimum_deployment_target=minimum_deployment_target,
            inputs=list(inputs),
            outputs=list(outputs),
        )
        op_counts = inspect_mil_ops(**inspect_kwargs)
        print_op_summary(label, op_counts)
    else:
        print(f"Skipping MIL op inspection for {label}")

    started = time.perf_counter()
    mlmodel = ct.convert(
        module,
        convert_to="mlprogram",
        minimum_deployment_target=minimum_deployment_target,
        compute_units=compute_units,
        compute_precision=compute_precision,
        inputs=list(inputs),
        outputs=list(outputs),
    )
    save_mlpackage(mlmodel, output_path)
    elapsed = time.perf_counter() - started
    print(f"Saved {label} to {output_path} ({elapsed:.1f}s)")
    return mlmodel, op_counts


def verify_model(package_path: Path, inputs: Mapping[str, np.ndarray], *, compute_units: ct.ComputeUnit) -> dict[str, np.ndarray]:
    started = time.perf_counter()
    model = ct.models.MLModel(str(package_path), compute_units=compute_units)
    load_ms = (time.perf_counter() - started) * 1000.0

    started = time.perf_counter()
    outputs = model.predict(dict(inputs))
    predict_ms = (time.perf_counter() - started) * 1000.0

    print(f"Verified {package_path.name}: load={load_ms:.1f} ms predict={predict_ms:.1f} ms")
    result: dict[str, np.ndarray] = {}
    for key, value in outputs.items():
        array = np.asarray(value)
        result[key] = array
        print(f"  {key}: shape={array.shape} dtype={array.dtype}")
    return result


def compute_plan_summary(package_path: Path, compute_units: ct.ComputeUnit) -> Counter[str] | None:
    try:
        model = ct.models.MLModel(str(package_path), compute_units=compute_units)
        compiled_path = model.get_compiled_model_path()
        if compiled_path is None:
            return None
        plan = ct.models.compute_plan.MLComputePlan.load_from_path(
            compiled_path,
            compute_units=compute_units,
        )
        program = plan.model_structure.program
        if program is None:
            return None
        counts: Counter[str] = Counter()
        for operation in program.functions["main"].block.operations:
            usage = plan.get_compute_device_usage_for_mlprogram_operation(operation)
            if usage is None or usage.preferred_compute_device is None:
                continue
            counts[type(usage.preferred_compute_device).__name__] += 1
        return counts
    except Exception as exc:
        print(f"Compute plan unavailable for {package_path.name}: {type(exc).__name__}: {exc}")
        return None


def to_numpy(value: torch.Tensor, *, dtype) -> np.ndarray:
    return np.asarray(value.detach().cpu().numpy(), dtype=dtype)


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

    input_ids, input_lengths, attention_mask, ref_s, speed = build_example_inputs(args.max_tokens)
    prosody_style = ref_s[:, 128:]
    acoustic_style = ref_s[:, :128]

    monolith = KokoroCoreMLANEWrapperV2(
        kmodel,
        max_tokens=args.max_tokens,
        max_frames=args.max_frames,
    ).eval()
    albert = AlbertEncoderSegment(kmodel).eval()
    prosody = ProsodyPredictorSegment(kmodel, max_frames=args.max_frames).eval()
    text_encoder = TextEncoderSegment(kmodel).eval()
    decoder = DecoderSegment(kmodel).eval()

    monolith_outputs = run_torch_smoke(
        monolith,
        (input_ids, input_lengths, ref_s, speed),
        "Monolith v2",
    )
    bert_output, = run_torch_smoke(
        albert,
        (input_ids, attention_mask),
        "Segment 1 / ALBERT",
    )
    prosody_outputs = run_torch_smoke(
        prosody,
        (bert_output, input_lengths, prosody_style, speed),
        "Segment 2 / Prosody",
    )
    text_outputs = run_torch_smoke(
        text_encoder,
        (input_ids, input_lengths),
        "Segment 3 / Text encoder",
    )

    pred_dur = torch.round(prosody_outputs[0]).to(dtype=torch.long)
    frame_lengths = pred_dur.sum(dim=-1)
    alignment = ProsodyPredictorSegment._build_alignment(pred_dur, args.max_frames, text_outputs[0].dtype)
    asr = text_outputs[0].to(dtype=ref_s.dtype) @ alignment
    decoder_outputs = run_torch_smoke(
        decoder,
        (asr, prosody_outputs[1], prosody_outputs[2], acoustic_style, frame_lengths),
        "Segment 4 / Decoder",
    )

    monolith_audio = monolith_outputs[0].detach().cpu().numpy()
    segmented_audio = decoder_outputs[0].detach().cpu().numpy()
    audio_diff = float(np.max(np.abs(monolith_audio - segmented_audio)))
    pred_dur_diff = float(np.max(np.abs(monolith_outputs[1].detach().cpu().numpy() - prosody_outputs[0].detach().cpu().numpy())))
    print(f"Segmented vs monolith PyTorch audio max abs diff: {audio_diff:.6f}")
    print(f"Segmented vs monolith PyTorch pred_dur max abs diff: {pred_dur_diff:.6f}")

    monolith_package = args.output_dir / DEFAULT_MONOLITH_OUTPUT.name
    segmented_dir = args.segmented_output_dir
    segmented_dir.mkdir(parents=True, exist_ok=True)

    artifacts: list[tuple[str, Path, ct.ComputeUnit, dict[str, np.ndarray]]] = []

    if not args.skip_monolith_v2:
        if audio_diff > 1e-2 or pred_dur_diff > 1e-3:
            print(
                "Skipping monolith v2 export because the fixed-shape dense-LSTM path does not match the segmented reference closely enough."
            )
        else:
            monolith_torchscript, monolith_mode = script_or_trace_module(
                monolith,
                (input_ids, input_lengths, ref_s, speed),
                label="monolith v2",
                prefer_script=True,
            )
            print(f"Using {monolith_mode} for monolith v2 export")
            try:
                convert_mlprogram(
                    label="kokoro_ane_v2.mlpackage",
                    module=monolith_torchscript,
                    output_path=monolith_package,
                    minimum_deployment_target=deployment_target,
                    compute_units=ct.ComputeUnit.ALL,
                    compute_precision=ct.precision.FLOAT16,
                    inspect_ops=not args.skip_op_inspection,
                    inputs=[
                        ct.TensorType(name="input_ids", shape=(1, args.max_tokens), dtype=np.int32),
                        ct.TensorType(name="input_lengths", shape=(1,), dtype=np.int32),
                        ct.TensorType(name="ref_s", shape=(1, 256), dtype=np.float32),
                        ct.TensorType(name="speed", shape=(1,), dtype=np.float32),
                    ],
                    outputs=[
                        ct.TensorType(name="audio"),
                        ct.TensorType(name="pred_dur"),
                    ],
                )
                artifacts.append(
                    (
                        "monolith-v2",
                        monolith_package,
                        ct.ComputeUnit.ALL,
                        {
                            "input_ids": to_numpy(input_ids, dtype=np.int32),
                            "input_lengths": to_numpy(input_lengths, dtype=np.int32),
                            "ref_s": to_numpy(ref_s, dtype=np.float32),
                            "speed": to_numpy(speed, dtype=np.float32),
                        },
                    )
                )
            except Exception as exc:
                print(f"Monolith v2 export failed: {type(exc).__name__}: {exc}")

    albert_torchscript, albert_mode = script_or_trace_module(
        albert,
        (input_ids, attention_mask),
        label="segment 1 / ALBERT",
        prefer_script=False,
    )
    print(f"Using {albert_mode} for segment 1 export")
    albert_package = segmented_dir / "albert.mlpackage"
    convert_mlprogram(
        label="segment 1 / albert.mlpackage",
        module=albert_torchscript,
        output_path=albert_package,
        minimum_deployment_target=deployment_target,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT16,
        inspect_ops=not args.skip_op_inspection,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, args.max_tokens), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, args.max_tokens), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="bert_output")],
    )
    artifacts.append(
        (
            "segment-1-albert",
            albert_package,
            ct.ComputeUnit.ALL,
            {
                "input_ids": to_numpy(input_ids, dtype=np.int32),
                "attention_mask": to_numpy(attention_mask, dtype=np.int32),
            },
        )
    )

    prosody_torchscript, prosody_mode = script_or_trace_module(
        prosody,
        (bert_output, input_lengths, prosody_style, speed),
        label="segment 2 / prosody",
        prefer_script=True,
    )
    print(f"Using {prosody_mode} for segment 2 export")
    prosody_package = segmented_dir / "prosody.mlpackage"
    convert_mlprogram(
        label="segment 2 / prosody.mlpackage",
        module=prosody_torchscript,
        output_path=prosody_package,
        minimum_deployment_target=deployment_target,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        compute_precision=ct.precision.FLOAT32,
        inspect_ops=not args.skip_op_inspection,
        inputs=[
            ct.TensorType(name="bert_output", shape=(1, args.max_tokens, 768), dtype=np.float32),
            ct.TensorType(name="input_lengths", shape=(1,), dtype=np.int32),
            ct.TensorType(name="style", shape=(1, 128), dtype=np.float32),
            ct.TensorType(name="speed", shape=(1,), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="pred_dur"),
            ct.TensorType(name="f0_pred"),
            ct.TensorType(name="n_pred"),
        ],
    )
    artifacts.append(
        (
            "segment-2-prosody",
            prosody_package,
            ct.ComputeUnit.CPU_ONLY,
            {
                "bert_output": to_numpy(bert_output, dtype=np.float32),
                "input_lengths": to_numpy(input_lengths, dtype=np.int32),
                "style": to_numpy(prosody_style, dtype=np.float32),
                "speed": to_numpy(speed, dtype=np.float32),
            },
        )
    )

    text_torchscript, text_mode = script_or_trace_module(
        text_encoder,
        (input_ids, input_lengths),
        label="segment 3 / text encoder",
        prefer_script=True,
    )
    print(f"Using {text_mode} for segment 3 export")
    text_package = segmented_dir / "text_encoder.mlpackage"
    convert_mlprogram(
        label="segment 3 / text_encoder.mlpackage",
        module=text_torchscript,
        output_path=text_package,
        minimum_deployment_target=deployment_target,
        compute_units=ct.ComputeUnit.CPU_ONLY,
        compute_precision=ct.precision.FLOAT32,
        inspect_ops=not args.skip_op_inspection,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, args.max_tokens), dtype=np.int32),
            ct.TensorType(name="input_lengths", shape=(1,), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="t_en")],
    )
    artifacts.append(
        (
            "segment-3-text-encoder",
            text_package,
            ct.ComputeUnit.CPU_ONLY,
            {
                "input_ids": to_numpy(input_ids, dtype=np.int32),
                "input_lengths": to_numpy(input_lengths, dtype=np.int32),
            },
        )
    )

    decoder_torchscript, decoder_mode = script_or_trace_module(
        decoder,
        (asr, prosody_outputs[1], prosody_outputs[2], acoustic_style, frame_lengths),
        label="segment 4 / decoder",
        prefer_script=False,
    )
    print(f"Using {decoder_mode} for segment 4 export")
    decoder_package = segmented_dir / "decoder.mlpackage"
    asr_channels = int(asr.shape[1])
    convert_mlprogram(
        label="segment 4 / decoder.mlpackage",
        module=decoder_torchscript,
        output_path=decoder_package,
        minimum_deployment_target=deployment_target,
        compute_units=ct.ComputeUnit.ALL,
        compute_precision=ct.precision.FLOAT16,
        inspect_ops=not args.skip_op_inspection,
        inputs=[
            ct.TensorType(name="asr", shape=(1, asr_channels, args.max_frames), dtype=np.float32),
            ct.TensorType(name="f0_curve", shape=(1, args.max_frames * 2), dtype=np.float32),
            ct.TensorType(name="n", shape=(1, args.max_frames * 2), dtype=np.float32),
            ct.TensorType(name="acoustic_style", shape=(1, 128), dtype=np.float32),
            ct.TensorType(name="frame_lengths", shape=(1,), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="audio")],
    )
    artifacts.append(
        (
            "segment-4-decoder",
            decoder_package,
            ct.ComputeUnit.ALL,
            {
                "asr": to_numpy(asr, dtype=np.float32),
                "f0_curve": to_numpy(prosody_outputs[1], dtype=np.float32),
                "n": to_numpy(prosody_outputs[2], dtype=np.float32),
                "acoustic_style": to_numpy(acoustic_style, dtype=np.float32),
                "frame_lengths": to_numpy(frame_lengths.to(dtype=torch.int32), dtype=np.int32),
            },
        )
    )

    if args.skip_verify:
        return

    for label, package_path, compute_units, verify_inputs in artifacts:
        verify_model(package_path, verify_inputs, compute_units=compute_units)
        device_counts = compute_plan_summary(package_path, compute_units)
        if device_counts:
            summary = ", ".join(f"{name}={count}" for name, count in device_counts.items())
            print(f"  compute-plan preferred devices for {label}: {summary}")


if __name__ == "__main__":
    main()
