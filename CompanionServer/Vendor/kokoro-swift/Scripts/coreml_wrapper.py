#!/usr/bin/env python3
"""CoreML export wrappers for Kokoro-82M.

This module avoids editing the original Kokoro sources under ``python_originals/``.
It loads the model files directly, patches export-only behavior in memory, and
provides two wrapper surfaces:

* ``KokoroCoreMLANEWrapper``
    Fixed-token export surface intended for ML Program / ANE-friendly export.
* ``KokoroCoreMLCPUWrapper``
    Flexible-token export surface intended for CPU-only export.

Key export accommodations:

* bypass ``kokoro.__init__`` so local export does not require Misaki / demo deps
* remove stochastic source-generation noise for deterministic tracing/conversion
* replace packed-sequence dependence with export-friendly LSTM execution
* build a fixed-size alignment matrix with broadcast masks instead of
  ``torch.repeat_interleave`` + scatter indexing
* cap audio to a fixed frame bucket so CoreML output shapes stay bounded
"""

from __future__ import annotations

import importlib.util
import math
import sys
import types
from pathlib import Path
from typing import Optional

import torch
import torch.nn as nn
import torch.nn.functional as F

DEFAULT_MAX_TOKENS = 512
# Conservative default export bucket: enough for one frame per token at the
# maximum token count, while keeping compiled CoreML packages tractable.
DEFAULT_MAX_FRAMES = 512
SAMPLES_PER_FRAME = 600  # 24 kHz / 40 fps


class _LoggerStub:
    def debug(self, *args, **kwargs) -> None:
        return None



def _ensure_loguru_stub() -> None:
    if "loguru" not in sys.modules:
        sys.modules["loguru"] = types.SimpleNamespace(logger=_LoggerStub())



def _load_local_kokoro_package(source_dir: Path) -> None:
    """Load ``kokoro`` submodules without executing ``kokoro.__init__``.

    The original package ``__init__`` pulls in pipeline/demo dependencies that are
    irrelevant for checkpoint export and are not guaranteed to be installed in the
    local environment.
    """

    _ensure_loguru_stub()

    package_name = "kokoro"
    existing_pkg = sys.modules.get(package_name)
    if existing_pkg is None or not hasattr(existing_pkg, "__path__"):
        pkg = types.ModuleType(package_name)
        pkg.__path__ = [str(source_dir)]
        sys.modules[package_name] = pkg
    else:
        pkg_paths = list(getattr(existing_pkg, "__path__", []))
        if str(source_dir) not in pkg_paths:
            existing_pkg.__path__ = [str(source_dir), *pkg_paths]

    for module_name in ("custom_stft", "istftnet", "modules", "model"):
        full_name = f"kokoro.{module_name}"
        module = sys.modules.get(full_name)
        module_path = source_dir / f"{module_name}.py"
        if module is not None and getattr(module, "__file__", None) == str(module_path):
            continue

        spec = importlib.util.spec_from_file_location(full_name, module_path)
        if spec is None or spec.loader is None:
            raise RuntimeError(f"Unable to load Kokoro module from {module_path}")
        module = importlib.util.module_from_spec(spec)
        sys.modules[full_name] = module
        spec.loader.exec_module(module)



def load_kmodel(
    repo_root: Path,
    config_path: Path,
    checkpoint_path: Path,
    *,
    disable_complex: bool = True,
) -> nn.Module:
    """Instantiate ``KModel`` from local sources and patch it for export."""

    source_dir = (repo_root / "python_originals" / "kokoro_py" / "kokoro").resolve()
    _load_local_kokoro_package(source_dir)

    from kokoro.model import KModel  # type: ignore

    model = KModel(
        repo_id="hexgrad/Kokoro-82M",
        config=str(config_path),
        model=str(checkpoint_path),
        disable_complex=disable_complex,
    )
    if hasattr(model.bert, "set_attn_implementation"):
        model.bert.set_attn_implementation("eager")
    elif hasattr(model.bert, "config") and hasattr(model.bert.config, "_attn_implementation"):
        model.bert.config._attn_implementation = "eager"
    model.eval()
    patch_model_for_export(model)
    return model


class DeterministicSineGen(nn.Module):
    """Export-safe replacement for ``SineGen``.

    The original implementation injects random phase offsets and Gaussian noise.
    Those random ops are not appropriate for deterministic CoreML export, so this
    variant preserves the harmonic construction while removing stochastic terms.
    """

    def __init__(self, original: nn.Module):
        super().__init__()
        self.sine_amp = float(original.sine_amp)
        self.noise_std = float(original.noise_std)
        self.harmonic_num = int(original.harmonic_num)
        self.dim = int(original.dim)
        self.sampling_rate = float(original.sampling_rate)
        self.voiced_threshold = float(original.voiced_threshold)
        self.flag_for_pulse = bool(original.flag_for_pulse)
        self.upsample_scale = int(original.upsample_scale)
        harmonics = torch.arange(1, self.harmonic_num + 2, dtype=torch.float32).view(1, 1, -1)
        self.register_buffer("harmonics", harmonics)

    def _f02uv(self, f0: torch.Tensor) -> torch.Tensor:
        return (f0 > self.voiced_threshold).to(torch.float32)

    def _f02sine(self, f0_values: torch.Tensor) -> torch.Tensor:
        rad_values = (f0_values / self.sampling_rate) % 1
        if not self.flag_for_pulse:
            rad_values = F.interpolate(
                rad_values.transpose(1, 2),
                scale_factor=1 / self.upsample_scale,
                mode="linear",
            ).transpose(1, 2)
            phase = torch.cumsum(rad_values, dim=1) * (2.0 * torch.pi)
            phase = F.interpolate(
                phase.transpose(1, 2) * self.upsample_scale,
                scale_factor=self.upsample_scale,
                mode="linear",
            ).transpose(1, 2)
            return torch.sin(phase)

        uv = self._f02uv(f0_values)
        uv_1 = torch.roll(uv, shifts=-1, dims=1)
        uv_1[:, -1, :] = 1
        u_loc = (uv < 1) * (uv_1 > 0)
        tmp_cumsum = torch.cumsum(rad_values, dim=1)
        for batch_index in range(f0_values.shape[0]):
            temp_sum = tmp_cumsum[batch_index, u_loc[batch_index, :, 0], :]
            temp_sum[1:, :] = temp_sum[1:, :] - temp_sum[0:-1, :]
            tmp_cumsum[batch_index, :, :] = 0
            tmp_cumsum[batch_index, u_loc[batch_index, :, 0], :] = temp_sum
        i_phase = torch.cumsum(rad_values - tmp_cumsum, dim=1)
        return torch.cos(i_phase * (2.0 * torch.pi))

    def forward(self, f0: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        harmonic_scale = self.harmonics.to(device=f0.device, dtype=f0.dtype)
        fn = f0 * harmonic_scale
        sine_waves = self._f02sine(fn) * self.sine_amp
        uv = self._f02uv(f0).to(dtype=f0.dtype)
        noise_amp = uv * self.noise_std + (1.0 - uv) * (self.sine_amp / 3.0)
        pseudo_noise = torch.sin(torch.cumsum((fn / self.sampling_rate) % 1, dim=1) * (2.0 * torch.pi * 13.0))
        noise = noise_amp * pseudo_noise
        sine_waves = sine_waves * uv + noise
        return sine_waves, uv, noise


class DeterministicSourceModuleHnNSF(nn.Module):
    """Export-safe replacement for ``SourceModuleHnNSF``."""

    def __init__(self, original: nn.Module):
        super().__init__()
        self.sine_amp = float(original.sine_amp)
        self.noise_std = float(original.noise_std)
        self.l_sin_gen = DeterministicSineGen(original.l_sin_gen)
        self.l_linear = original.l_linear
        self.l_tanh = original.l_tanh

    def forward(self, f0: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor]:
        sine_wavs, uv, _ = self.l_sin_gen(f0)
        sine_merge = self.l_tanh(self.l_linear(sine_wavs))
        noise = torch.zeros_like(uv)
        return sine_merge, noise, uv



def _patched_adain_resblk_forward(self, x: torch.Tensor, s: torch.Tensor) -> torch.Tensor:
    out = self._residual(x, s)
    return (out + self._shortcut(x)) * math.sqrt(0.5)



def patch_model_for_export(model: nn.Module) -> None:
    """Patch stochastic submodules in-place for deterministic export."""

    generator = model.decoder.generator
    generator.m_source = DeterministicSourceModuleHnNSF(generator.m_source)

    for module in model.modules():
        if module.__class__.__name__ == "AdainResBlk1d":
            module.forward = types.MethodType(_patched_adain_resblk_forward, module)



def _lengths_to_padding_mask(lengths: torch.Tensor, max_length: int) -> torch.Tensor:
    positions = torch.arange(max_length, device=lengths.device, dtype=lengths.dtype).unsqueeze(0)
    return positions >= lengths.unsqueeze(1)



def _lstm_step(
    x_t: torch.Tensor,
    h_t: torch.Tensor,
    c_t: torch.Tensor,
    weight_ih: torch.Tensor,
    weight_hh: torch.Tensor,
    bias_ih: Optional[torch.Tensor],
    bias_hh: Optional[torch.Tensor],
) -> tuple[torch.Tensor, torch.Tensor]:
    gates = F.linear(x_t, weight_ih, bias_ih) + F.linear(h_t, weight_hh, bias_hh)
    i_t, f_t, g_t, o_t = gates.chunk(4, dim=-1)
    i_t = torch.sigmoid(i_t)
    f_t = torch.sigmoid(f_t)
    g_t = torch.tanh(g_t)
    o_t = torch.sigmoid(o_t)
    c_next = f_t * c_t + i_t * g_t
    h_next = o_t * torch.tanh(c_next)
    return h_next, c_next



def run_masked_bilstm(
    lstm: nn.LSTM,
    x: torch.Tensor,
    lengths: torch.Tensor,
) -> torch.Tensor:
    """Run a one-layer bidirectional LSTM while freezing state on padded steps.

    This is used only on padded fixed-shape export paths where the original model
    relied on packed sequences or implicitly assumed unpadded inputs.
    """

    if not lstm.bidirectional or lstm.num_layers != 1 or not lstm.batch_first:
        raise ValueError("run_masked_bilstm expects a one-layer bidirectional batch-first LSTM")

    lengths = lengths.to(dtype=torch.long)
    batch_size, time_steps, _ = x.shape
    hidden_size = lstm.hidden_size
    zero_state = x.new_zeros(batch_size, hidden_size)

    h_f = zero_state
    c_f = zero_state
    forward_outputs: list[torch.Tensor] = []
    for step in range(time_steps):
        valid = (step < lengths).unsqueeze(-1)
        next_h, next_c = _lstm_step(
            x[:, step, :],
            h_f,
            c_f,
            lstm.weight_ih_l0,
            lstm.weight_hh_l0,
            lstm.bias_ih_l0,
            lstm.bias_hh_l0,
        )
        h_f = torch.where(valid, next_h, h_f)
        c_f = torch.where(valid, next_c, c_f)
        forward_outputs.append(torch.where(valid, h_f, zero_state))

    h_b = zero_state
    c_b = zero_state
    backward_outputs: list[Optional[torch.Tensor]] = [None] * time_steps
    for reverse_step, step in enumerate(range(time_steps - 1, -1, -1)):
        del reverse_step
        valid = (step < lengths).unsqueeze(-1)
        next_h, next_c = _lstm_step(
            x[:, step, :],
            h_b,
            c_b,
            lstm.weight_ih_l0_reverse,
            lstm.weight_hh_l0_reverse,
            lstm.bias_ih_l0_reverse,
            lstm.bias_hh_l0_reverse,
        )
        h_b = torch.where(valid, next_h, h_b)
        c_b = torch.where(valid, next_c, c_b)
        backward_outputs[step] = torch.where(valid, h_b, zero_state)

    backward = torch.stack([tensor for tensor in backward_outputs if tensor is not None], dim=1)
    forward = torch.stack(forward_outputs, dim=1)
    return torch.cat([forward, backward], dim=-1)


class ExportTextEncoder(nn.Module):
    def __init__(self, original: nn.Module, *, masked_lstm: bool):
        super().__init__()
        self.embedding = original.embedding
        self.cnn = original.cnn
        self.lstm = original.lstm
        self.masked_lstm = masked_lstm

    def forward(self, input_ids: torch.Tensor, lengths: torch.Tensor, padding_mask: torch.Tensor) -> torch.Tensor:
        x = self.embedding(input_ids).transpose(1, 2)
        channel_mask = padding_mask.unsqueeze(1)
        x = x.masked_fill(channel_mask, 0.0)
        for block in self.cnn:
            x = block(x)
            x = x.masked_fill(channel_mask, 0.0)
        x = x.transpose(1, 2)
        if self.masked_lstm:
            x = run_masked_bilstm(self.lstm, x, lengths)
        else:
            self.lstm.flatten_parameters()
            x, _ = self.lstm(x)
        x = x.transpose(-1, -2)
        x = x.masked_fill(channel_mask, 0.0)
        return x


class ExportDurationEncoder(nn.Module):
    def __init__(self, original: nn.Module, *, masked_lstm: bool):
        super().__init__()
        self.lstms = original.lstms
        self.dropout = float(original.dropout)
        self.masked_lstm = masked_lstm

    def forward(self, x: torch.Tensor, style: torch.Tensor, lengths: torch.Tensor, padding_mask: torch.Tensor) -> torch.Tensor:
        masks = padding_mask
        x = x.permute(2, 0, 1)
        style_expanded = style.expand(x.shape[0], x.shape[1], -1)
        x = torch.cat([x, style_expanded], dim=-1)
        x = x.masked_fill(masks.unsqueeze(-1).transpose(0, 1), 0.0)
        x = x.transpose(0, 1).transpose(-1, -2)

        for block in self.lstms:
            if isinstance(block, nn.LSTM):
                sequence = x.transpose(-1, -2)
                if self.masked_lstm:
                    sequence = run_masked_bilstm(block, sequence, lengths)
                else:
                    block.flatten_parameters()
                    sequence, _ = block(sequence)
                sequence = F.dropout(sequence, p=self.dropout, training=False)
                x = sequence.transpose(-1, -2)
                x = x.masked_fill(masks.unsqueeze(1), 0.0)
                continue

            x = block(x.transpose(-1, -2), style).transpose(-1, -2)
            x = torch.cat([x, style_expanded.permute(1, 2, 0)], dim=1)
            x = x.masked_fill(masks.unsqueeze(1), 0.0)

        return x.transpose(-1, -2)


class BaseKokoroCoreMLWrapper(nn.Module):
    def __init__(
        self,
        kmodel: nn.Module,
        *,
        max_tokens: int = DEFAULT_MAX_TOKENS,
        max_frames: int = DEFAULT_MAX_FRAMES,
        masked_token_lstm: bool,
    ):
        super().__init__()
        self.kmodel = kmodel
        self.max_tokens = int(max_tokens)
        self.max_frames = int(max_frames)
        self.max_audio_samples = int(max_frames * SAMPLES_PER_FRAME)
        self.model_dtype = next(kmodel.parameters()).dtype

        self.text_encoder = ExportTextEncoder(kmodel.text_encoder, masked_lstm=masked_token_lstm)
        self.duration_encoder = ExportDurationEncoder(kmodel.predictor.text_encoder, masked_lstm=masked_token_lstm)
        self.duration_lstm = kmodel.predictor.lstm
        self.duration_proj = kmodel.predictor.duration_proj
        self.frame_lstm = kmodel.predictor.shared
        self.f0_blocks = kmodel.predictor.F0
        self.n_blocks = kmodel.predictor.N
        self.f0_proj = kmodel.predictor.F0_proj
        self.n_proj = kmodel.predictor.N_proj
        self.decoder = kmodel.decoder
        self.bert = kmodel.bert
        self.bert_encoder = kmodel.bert_encoder

    def _run_plbert(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        input_ids_long = input_ids.to(dtype=torch.long)
        token_type_ids = torch.zeros_like(input_ids_long)
        embedding_output = self.bert.embeddings(
            input_ids_long,
            token_type_ids=token_type_ids,
        )
        additive_mask = (1.0 - attention_mask.to(dtype=embedding_output.dtype))[:, None, None, :]
        additive_mask = additive_mask * torch.full(
            (),
            -1.0e4,
            device=embedding_output.device,
            dtype=embedding_output.dtype,
        )
        encoder_outputs = self.bert.encoder(
            embedding_output,
            additive_mask,
        )
        if hasattr(encoder_outputs, "last_hidden_state"):
            return encoder_outputs.last_hidden_state
        return encoder_outputs[0]

    def _prepare_inputs(
        self,
        input_ids: torch.Tensor,
        lengths: torch.Tensor,
        ref_s: torch.Tensor,
        speed: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        input_ids = input_ids.to(dtype=torch.int32)
        lengths = lengths.to(dtype=torch.long)
        ref_s = ref_s.to(dtype=self.model_dtype)
        speed = speed.to(dtype=self.model_dtype)
        speed = speed.clamp_min(1e-3)
        return input_ids, lengths, ref_s, speed

    def _token_duration_path(
        self,
        d_en: torch.Tensor,
        style: torch.Tensor,
        lengths: torch.Tensor,
        token_padding_mask: torch.Tensor,
        speed: torch.Tensor,
        *,
        masked_token_lstm: bool,
    ) -> tuple[torch.Tensor, torch.Tensor, torch.Tensor, torch.Tensor]:
        d = self.duration_encoder(d_en, style, lengths, token_padding_mask)
        if masked_token_lstm:
            x = run_masked_bilstm(self.duration_lstm, d, lengths)
        else:
            self.duration_lstm.flatten_parameters()
            x, _ = self.duration_lstm(d)
        duration_logits = self.duration_proj(x)
        duration = torch.sigmoid(duration_logits).sum(dim=-1) / speed.unsqueeze(-1)
        duration = torch.round(duration).clamp(min=1).to(dtype=torch.long)
        valid_tokens = ~token_padding_mask
        duration = torch.where(valid_tokens, duration, torch.zeros_like(duration))
        duration = self._truncate_durations(duration, self.max_frames)
        alignment = self._build_alignment(duration, self.max_frames, d.dtype)
        encoded = d.transpose(-1, -2) @ alignment
        frame_lengths = duration.sum(dim=-1)
        return duration, alignment, encoded, frame_lengths

    @staticmethod
    def _truncate_durations(duration: torch.Tensor, max_frames: int) -> torch.Tensor:
        cumulative = torch.cumsum(duration, dim=-1)
        clipped_end = torch.clamp(cumulative, max=max_frames)
        clipped_start = F.pad(clipped_end[..., :-1], (1, 0), value=0)
        used = clipped_end - clipped_start
        return torch.clamp(used, min=0)

    @staticmethod
    def _build_alignment(duration: torch.Tensor, max_frames: int, dtype: torch.dtype) -> torch.Tensor:
        ends = torch.cumsum(duration, dim=-1)
        starts = ends - duration
        frame_positions = torch.arange(max_frames, device=duration.device, dtype=duration.dtype).view(1, 1, -1)
        alignment = (frame_positions >= starts.unsqueeze(-1)) & (frame_positions < ends.unsqueeze(-1))
        return alignment.to(dtype=dtype)

    def _predict_f0_n(self, encoded: torch.Tensor, style: torch.Tensor, frame_lengths: torch.Tensor) -> tuple[torch.Tensor, torch.Tensor]:
        shared_in = encoded.transpose(-1, -2)
        shared_out = run_masked_bilstm(self.frame_lstm, shared_in, frame_lengths)
        f0 = shared_out.transpose(-1, -2)
        for block in self.f0_blocks:
            f0 = block(f0, style)
        f0 = self.f0_proj(f0).squeeze(1)

        noise = shared_out.transpose(-1, -2)
        for block in self.n_blocks:
            noise = block(noise, style)
        noise = self.n_proj(noise).squeeze(1)

        max_f0_frames = f0.shape[-1]
        f0_padding_mask = _lengths_to_padding_mask(frame_lengths * 2, max_f0_frames)
        f0 = torch.where(f0_padding_mask, torch.zeros_like(f0), f0)
        noise = torch.where(f0_padding_mask, torch.zeros_like(noise), noise)
        return f0, noise

    def _run_decoder(
        self,
        encoded: torch.Tensor,
        f0: torch.Tensor,
        noise: torch.Tensor,
        ref_s: torch.Tensor,
        frame_lengths: torch.Tensor,
    ) -> torch.Tensor:
        audio = self.decoder(encoded, f0, noise, ref_s[:, :128]).squeeze(1)
        audio_padding_mask = _lengths_to_padding_mask(frame_lengths * SAMPLES_PER_FRAME, audio.shape[-1])
        audio = torch.where(audio_padding_mask, torch.zeros_like(audio), audio)
        return audio

    def _forward_impl(
        self,
        input_ids: torch.Tensor,
        lengths: torch.Tensor,
        ref_s: torch.Tensor,
        speed: torch.Tensor,
        *,
        masked_token_lstm: bool,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        input_ids, lengths, ref_s, speed = self._prepare_inputs(input_ids, lengths, ref_s, speed)
        batch_size, token_count = input_ids.shape
        del batch_size
        token_padding_mask = _lengths_to_padding_mask(lengths, token_count)
        attention_mask = (~token_padding_mask).to(dtype=torch.int32)

        bert_dur = self._run_plbert(input_ids, attention_mask)
        d_en = self.bert_encoder(bert_dur).transpose(-1, -2)
        style = ref_s[:, 128:]

        pred_dur, alignment, encoded, frame_lengths = self._token_duration_path(
            d_en,
            style,
            lengths,
            token_padding_mask,
            speed,
            masked_token_lstm=masked_token_lstm,
        )

        f0, noise = self._predict_f0_n(encoded, style, frame_lengths)
        t_en = self.text_encoder(input_ids.to(dtype=torch.long), lengths, token_padding_mask)
        asr = t_en @ alignment
        audio = self._run_decoder(asr, f0, noise, ref_s, frame_lengths)
        return audio, pred_dur


class KokoroCoreMLANEWrapper(BaseKokoroCoreMLWrapper):
    def __init__(self, kmodel: nn.Module, *, max_tokens: int = DEFAULT_MAX_TOKENS, max_frames: int = DEFAULT_MAX_FRAMES):
        super().__init__(
            kmodel,
            max_tokens=max_tokens,
            max_frames=max_frames,
            masked_token_lstm=True,
        )

    def forward(
        self,
        input_ids: torch.Tensor,
        input_lengths: torch.Tensor,
        ref_s: torch.Tensor,
        speed: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        lengths = torch.clamp(input_lengths.to(dtype=torch.long), min=1, max=input_ids.shape[1])
        return self._forward_impl(
            input_ids,
            lengths,
            ref_s,
            speed,
            masked_token_lstm=True,
        )


class KokoroCoreMLCPUWrapper(BaseKokoroCoreMLWrapper):
    """Flexible-token CPU export wrapper.

    The CPU path keeps flexible token length, so callers should pass exact-length
    (unpadded) ``input_ids`` and set ``input_lengths`` to the same token count.
    """

    def __init__(self, kmodel: nn.Module, *, max_tokens: int = DEFAULT_MAX_TOKENS, max_frames: int = DEFAULT_MAX_FRAMES):
        super().__init__(
            kmodel,
            max_tokens=max_tokens,
            max_frames=max_frames,
            masked_token_lstm=False,
        )

    def forward(
        self,
        input_ids: torch.Tensor,
        input_lengths: torch.Tensor,
        ref_s: torch.Tensor,
        speed: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        lengths = torch.clamp(input_lengths.to(dtype=torch.long), min=1, max=input_ids.shape[1])
        return self._forward_impl(
            input_ids,
            lengths,
            ref_s,
            speed,
            masked_token_lstm=False,
        )
