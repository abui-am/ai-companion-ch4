#!/usr/bin/env python3
"""
Convert Kokoro's original PyTorch checkpoint into a safetensors file that the
Swift MLX port can load directly, and convert voice packs into .npy arrays.

This script intentionally preserves almost all original parameter names; it only:
  * flattens the grouped top-level checkpoint into one safetensors file
  * strips the leading `module.` prefix produced by DataParallel wrapping
  * writes voice packs as standalone `.npy` arrays
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

import numpy as np
import torch
from safetensors.torch import save_file


def flatten_checkpoint(checkpoint_path: Path) -> dict[str, torch.Tensor]:
    checkpoint = torch.load(checkpoint_path, map_location="cpu", weights_only=True)
    flat: dict[str, torch.Tensor] = {}

    for module_name, state_dict in checkpoint.items():
        for key, value in state_dict.items():
            clean_key = key[7:] if key.startswith("module.") else key
            clean_key = remap_key(module_name, clean_key)
            if not clean_key:
                continue
            flat[f"{module_name}.{clean_key}"] = value.detach().cpu().contiguous()

    return flat


def remap_key(module_name: str, key: str) -> str:
    if module_name == "bert":
        if key.startswith("pooler."):
            return ""
        key = key.replace("albert_layer_groups", "albertLayerGroups")
        key = key.replace("albert_layers", "albertLayers")
        return key

    if module_name == "text_encoder" and key.startswith("cnn."):
        parts = key.split(".")
        if len(parts) > 2 and parts[2] == "0":
            parts[2] = "conv"
        elif len(parts) > 2 and parts[2] == "1":
            parts[2] = "norm"
        return ".".join(parts)

    if module_name == "decoder" and key.startswith("asr_res.0."):
        return key.replace("asr_res.0.", "asr_res.conv.", 1)

    return key


def convert_voices(voices_dir: Path, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    for voice_path in sorted(voices_dir.glob("*.pt")):
        if voice_path.name.startswith("._"):
            continue
        try:
            voice = torch.load(voice_path, map_location="cpu", weights_only=True)
        except Exception:
            # Some voice packs are older pickles that PyTorch's strict weights-only
            # loader rejects. These files are local trusted model assets, so we
            # deliberately fall back to the legacy loader.
            voice = torch.load(voice_path, map_location="cpu", weights_only=False)
        voice_np = voice.detach().cpu().numpy()
        np.save(output_dir / f"{voice_path.stem}.npy", voice_np)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=Path("Kokoro-82M/kokoro-v1_0.pth"),
    )
    parser.add_argument(
        "--voices",
        type=Path,
        default=Path("Kokoro-82M/voices"),
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("Kokoro-82M/config.json"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("MLX_GPU"),
    )
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)

    flat = flatten_checkpoint(args.checkpoint)
    save_file(
        flat,
        str(args.output_dir / "kokoro-v1_0.safetensors"),
        metadata={
            "source_checkpoint": str(args.checkpoint),
            "format": "kokoro-swift-mlx-v1",
        },
    )
    convert_voices(args.voices, args.output_dir / "voices")
    shutil.copy2(args.config, args.output_dir / "config.json")

    print(f"Saved model safetensors to {args.output_dir / 'kokoro-v1_0.safetensors'}")
    print(f"Saved converted voices to {args.output_dir / 'voices'}")


if __name__ == "__main__":
    main()
