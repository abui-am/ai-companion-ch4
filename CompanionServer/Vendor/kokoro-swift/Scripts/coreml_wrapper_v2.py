#!/usr/bin/env python3
"""Script-/trace-friendly CoreML export wrappers for Kokoro-82M.

This module keeps the existing export scripts untouched and provides a second
set of wrappers focused on preserving recurrent structure as real Torch LSTM
ops rather than lowering them into scalar gate math.

Design goals:

* reuse the existing loader/patching path from ``coreml_wrapper.py``
* keep LSTM-heavy paths in real ``nn.LSTM`` modules so Torch graphs retain
  ``aten::lstm``
* expose clean segment wrappers that follow ``KModel.forward_with_tokens``
* keep all changes additive; do not modify upstream ``python_originals``
"""

from __future__ import annotations

from typing import Tuple

import torch
import torch.nn as nn
import torch.nn.functional as F

from coreml_wrapper import (  # noqa: F401
    DEFAULT_MAX_FRAMES,
    DEFAULT_MAX_TOKENS,
    SAMPLES_PER_FRAME,
    load_kmodel,
    run_masked_bilstm,
)


TensorTriplet = Tuple[torch.Tensor, torch.Tensor, torch.Tensor]
ProsodyInternal = Tuple[
    torch.Tensor,  # pred_dur_int
    torch.Tensor,  # pred_dur_float
    torch.Tensor,  # alignment
    torch.Tensor,  # encoded
    torch.Tensor,  # f0
    torch.Tensor,  # noise
    torch.Tensor,  # frame_lengths
]


class RecurrentBiLSTM(nn.Module):
    """Selectable LSTM execution mode for export surfaces.

    Modes:
    * ``dense``  - direct ``nn.LSTM`` call; preserves ``aten::lstm`` in trace.
    * ``packed`` - pack/pad path; closer to eager semantics but may hit converter limits.
    * ``masked`` - fixed-shape masked fallback from the v1 exporter.
    """

    def __init__(self, lstm: nn.LSTM, *, mode: str):
        super().__init__()
        self.lstm = lstm
        self.batch_first = bool(lstm.batch_first)
        self.mode = mode

    def forward(self, x: torch.Tensor, lengths: torch.Tensor) -> torch.Tensor:
        if self.mode == "dense":
            out, _ = self.lstm(x)
            return out

        if self.mode == "masked":
            return run_masked_bilstm(self.lstm, x, lengths)

        packed_lengths = lengths.to(dtype=torch.int64).cpu()
        total_length = x.shape[1] if self.batch_first else x.shape[0]
        packed = nn.utils.rnn.pack_padded_sequence(
            x,
            packed_lengths,
            batch_first=self.batch_first,
            enforce_sorted=False,
        )
        packed_out, _ = self.lstm(packed)
        out, _ = nn.utils.rnn.pad_packed_sequence(
            packed_out,
            batch_first=self.batch_first,
            total_length=total_length,
        )
        return out


class ScriptableTextEncoder(nn.Module):
    def __init__(self, original: nn.Module, *, lstm_mode: str):
        super().__init__()
        self.embedding = original.embedding
        self.cnn = original.cnn
        self.lstm = RecurrentBiLSTM(original.lstm, mode=lstm_mode)

    def forward(
        self,
        input_ids: torch.Tensor,
        input_lengths: torch.Tensor,
        padding_mask: torch.Tensor,
    ) -> torch.Tensor:
        x = self.embedding(input_ids.to(dtype=torch.long)).transpose(1, 2)
        channel_mask = padding_mask.unsqueeze(1)
        x = x.masked_fill(channel_mask, 0.0)
        for block in self.cnn:
            x = block(x)
            x = x.masked_fill(channel_mask, 0.0)
        x = x.transpose(1, 2)
        x = self.lstm(x, input_lengths)
        x = x.transpose(1, 2)
        x = x.masked_fill(channel_mask, 0.0)
        return x


class ScriptableDurationEncoder(nn.Module):
    def __init__(self, original: nn.Module, *, lstm_mode: str):
        super().__init__()
        self.dropout = float(original.dropout)
        self.lstm_blocks = nn.ModuleList()
        self.norm_blocks = nn.ModuleList()
        original_blocks = list(original.lstms)
        for index in range(0, len(original_blocks), 2):
            self.lstm_blocks.append(RecurrentBiLSTM(original_blocks[index], mode=lstm_mode))
            self.norm_blocks.append(original_blocks[index + 1])

    def forward(
        self,
        x: torch.Tensor,
        style: torch.Tensor,
        text_lengths: torch.Tensor,
        padding_mask: torch.Tensor,
    ) -> torch.Tensor:
        masks = padding_mask
        x = x.permute(2, 0, 1)
        style_expanded = style.expand(x.shape[0], x.shape[1], -1)
        x = torch.cat([x, style_expanded], dim=-1)
        x = x.masked_fill(masks.unsqueeze(-1).transpose(0, 1), 0.0)
        x = x.transpose(0, 1).transpose(-1, -2)

        for lstm_block, norm_block in zip(self.lstm_blocks, self.norm_blocks):
            sequence = x.transpose(-1, -2)
            sequence = lstm_block(sequence, text_lengths)
            sequence = F.dropout(sequence, p=self.dropout, training=False)
            x = sequence.transpose(-1, -2)
            x = x.masked_fill(masks.unsqueeze(1), 0.0)
            x = norm_block(x.transpose(-1, -2), style).transpose(-1, -2)
            x = torch.cat([x, style_expanded.permute(1, 2, 0)], dim=1)
            x = x.masked_fill(masks.unsqueeze(1), 0.0)

        return x.transpose(-1, -2)


class AlbertEncoderSegment(nn.Module):
    def __init__(self, kmodel: nn.Module):
        super().__init__()
        self.bert = kmodel.bert
        self.model_dtype = next(kmodel.parameters()).dtype

    def forward(self, input_ids: torch.Tensor, attention_mask: torch.Tensor) -> torch.Tensor:
        input_ids = input_ids.to(dtype=torch.long)
        attention_mask = attention_mask.to(dtype=torch.int32)
        token_type_ids = torch.zeros_like(input_ids)
        embedding_output = self.bert.embeddings(
            input_ids,
            token_type_ids=token_type_ids,
        )
        additive_mask = (1.0 - attention_mask.to(dtype=embedding_output.dtype))[:, None, None, :]
        additive_mask = additive_mask * torch.tensor(
            -1.0e4,
            device=embedding_output.device,
            dtype=embedding_output.dtype,
        )
        encoder_outputs = self.bert.encoder(embedding_output, additive_mask)
        if hasattr(encoder_outputs, "last_hidden_state"):
            hidden = encoder_outputs.last_hidden_state
        else:
            hidden = encoder_outputs[0]
        return hidden.to(dtype=torch.float32)


class ProsodyPredictorSegment(nn.Module):
    def __init__(self, kmodel: nn.Module, *, max_frames: int = DEFAULT_MAX_FRAMES, lstm_mode: str = "masked"):
        super().__init__()
        self.max_frames = int(max_frames)
        self.model_dtype = next(kmodel.parameters()).dtype
        self.bert_encoder = kmodel.bert_encoder
        self.duration_encoder = ScriptableDurationEncoder(kmodel.predictor.text_encoder, lstm_mode=lstm_mode)
        self.duration_lstm = RecurrentBiLSTM(kmodel.predictor.lstm, mode=lstm_mode)
        self.duration_proj = kmodel.predictor.duration_proj
        self.shared_lstm = RecurrentBiLSTM(kmodel.predictor.shared, mode=lstm_mode)
        self.f0_blocks = kmodel.predictor.F0
        self.n_blocks = kmodel.predictor.N
        self.f0_proj = kmodel.predictor.F0_proj
        self.n_proj = kmodel.predictor.N_proj

    @staticmethod
    def _lengths_to_padding_mask(lengths: torch.Tensor, max_length: int) -> torch.Tensor:
        positions = torch.arange(max_length, device=lengths.device, dtype=lengths.dtype).unsqueeze(0)
        return positions >= lengths.unsqueeze(1)

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
        frame_positions = torch.arange(
            max_frames,
            device=duration.device,
            dtype=duration.dtype,
        ).view(1, 1, -1)
        alignment = (frame_positions >= starts.unsqueeze(-1)) & (frame_positions < ends.unsqueeze(-1))
        return alignment.to(dtype=dtype)

    def _predict_internal(
        self,
        bert_output: torch.Tensor,
        input_lengths: torch.Tensor,
        style: torch.Tensor,
        speed: torch.Tensor,
    ) -> ProsodyInternal:
        bert_output = bert_output.to(dtype=self.model_dtype)
        input_lengths = input_lengths.to(dtype=torch.long)
        style = style.to(dtype=self.model_dtype)
        speed = speed.to(dtype=self.model_dtype).clamp_min(1e-3)

        token_padding_mask = self._lengths_to_padding_mask(input_lengths, bert_output.shape[1])
        d_en = self.bert_encoder(bert_output).transpose(-1, -2)
        d = self.duration_encoder(d_en, style, input_lengths, token_padding_mask)

        duration_hidden = self.duration_lstm(d, input_lengths)
        duration_logits = self.duration_proj(duration_hidden)
        pred_dur_int = torch.sigmoid(duration_logits).sum(dim=-1) / speed.unsqueeze(-1)
        pred_dur_int = torch.round(pred_dur_int).clamp(min=1).to(dtype=torch.long)
        pred_dur_int = torch.where(
            ~token_padding_mask,
            pred_dur_int,
            torch.zeros_like(pred_dur_int),
        )
        pred_dur_int = self._truncate_durations(pred_dur_int, self.max_frames)
        pred_dur_float = pred_dur_int.to(dtype=torch.float32)

        alignment = self._build_alignment(pred_dur_int, self.max_frames, d.dtype)
        encoded = d.transpose(-1, -2) @ alignment
        frame_lengths = pred_dur_int.sum(dim=-1)

        shared_in = encoded.transpose(-1, -2)
        shared_out = self.shared_lstm(shared_in, frame_lengths)

        f0 = shared_out.transpose(-1, -2)
        for block in self.f0_blocks:
            f0 = block(f0, style)
        f0 = self.f0_proj(f0).squeeze(1)

        noise = shared_out.transpose(-1, -2)
        for block in self.n_blocks:
            noise = block(noise, style)
        noise = self.n_proj(noise).squeeze(1)

        frame_padding_mask = self._lengths_to_padding_mask(frame_lengths * 2, f0.shape[-1])
        f0 = torch.where(frame_padding_mask, torch.zeros_like(f0), f0)
        noise = torch.where(frame_padding_mask, torch.zeros_like(noise), noise)
        return pred_dur_int, pred_dur_float, alignment, encoded, f0, noise, frame_lengths

    def forward(
        self,
        bert_output: torch.Tensor,
        input_lengths: torch.Tensor,
        style: torch.Tensor,
        speed: torch.Tensor,
    ) -> TensorTriplet:
        _, pred_dur_float, _, _, f0, noise, _ = self._predict_internal(
            bert_output,
            input_lengths,
            style,
            speed,
        )
        return pred_dur_float, f0.to(dtype=torch.float32), noise.to(dtype=torch.float32)


class TextEncoderSegment(nn.Module):
    def __init__(self, kmodel: nn.Module, *, lstm_mode: str = "masked"):
        super().__init__()
        self.model_dtype = next(kmodel.parameters()).dtype
        self.text_encoder = ScriptableTextEncoder(kmodel.text_encoder, lstm_mode=lstm_mode)

    @staticmethod
    def _lengths_to_padding_mask(lengths: torch.Tensor, max_length: int) -> torch.Tensor:
        positions = torch.arange(max_length, device=lengths.device, dtype=lengths.dtype).unsqueeze(0)
        return positions >= lengths.unsqueeze(1)

    def forward(self, input_ids: torch.Tensor, input_lengths: torch.Tensor) -> torch.Tensor:
        input_lengths = input_lengths.to(dtype=torch.long)
        padding_mask = self._lengths_to_padding_mask(input_lengths, input_ids.shape[1])
        t_en = self.text_encoder(input_ids, input_lengths, padding_mask)
        return t_en.to(dtype=torch.float32)


class DecoderSegment(nn.Module):
    def __init__(self, kmodel: nn.Module):
        super().__init__()
        self.model_dtype = next(kmodel.parameters()).dtype
        self.decoder = kmodel.decoder

    @staticmethod
    def _lengths_to_padding_mask(lengths: torch.Tensor, max_length: int) -> torch.Tensor:
        positions = torch.arange(max_length, device=lengths.device, dtype=lengths.dtype).unsqueeze(0)
        return positions >= lengths.unsqueeze(1)

    def forward(
        self,
        asr: torch.Tensor,
        f0_curve: torch.Tensor,
        noise: torch.Tensor,
        acoustic_style: torch.Tensor,
        frame_lengths: torch.Tensor,
    ) -> torch.Tensor:
        frame_lengths = frame_lengths.to(dtype=torch.long)
        audio = self.decoder(
            asr.to(dtype=self.model_dtype),
            f0_curve.to(dtype=self.model_dtype),
            noise.to(dtype=self.model_dtype),
            acoustic_style.to(dtype=self.model_dtype),
        )
        audio_padding_mask = self._lengths_to_padding_mask(
            frame_lengths * SAMPLES_PER_FRAME,
            audio.shape[-1],
        ).unsqueeze(1)
        audio = torch.where(audio_padding_mask, torch.zeros_like(audio), audio)
        return audio.to(dtype=torch.float32)


class KokoroCoreMLANEWrapperV2(nn.Module):
    """Monolithic v2 wrapper that preserves recurrent structure where possible."""

    def __init__(
        self,
        kmodel: nn.Module,
        *,
        max_tokens: int = DEFAULT_MAX_TOKENS,
        max_frames: int = DEFAULT_MAX_FRAMES,
    ):
        super().__init__()
        self.max_tokens = int(max_tokens)
        self.max_frames = int(max_frames)
        self.model_dtype = next(kmodel.parameters()).dtype
        self.albert = AlbertEncoderSegment(kmodel)
        self.prosody = ProsodyPredictorSegment(kmodel, max_frames=max_frames, lstm_mode="dense")
        self.text_encoder = TextEncoderSegment(kmodel, lstm_mode="dense")
        self.decoder = DecoderSegment(kmodel)

    @staticmethod
    def _lengths_to_padding_mask(lengths: torch.Tensor, max_length: int) -> torch.Tensor:
        positions = torch.arange(max_length, device=lengths.device, dtype=lengths.dtype).unsqueeze(0)
        return positions >= lengths.unsqueeze(1)

    def forward(
        self,
        input_ids: torch.Tensor,
        input_lengths: torch.Tensor,
        ref_s: torch.Tensor,
        speed: torch.Tensor,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        input_ids = input_ids.to(dtype=torch.int32)
        input_lengths = torch.clamp(
            input_lengths.to(dtype=torch.long),
            min=1,
            max=input_ids.shape[1],
        )
        ref_s = ref_s.to(dtype=self.model_dtype)
        speed = speed.to(dtype=self.model_dtype)

        token_padding_mask = self._lengths_to_padding_mask(input_lengths, input_ids.shape[1])
        attention_mask = (~token_padding_mask).to(dtype=torch.int32)

        bert_output = self.albert(input_ids, attention_mask).to(dtype=self.model_dtype)
        pred_dur_int, pred_dur_float, alignment, _, f0, noise, frame_lengths = self.prosody._predict_internal(
            bert_output,
            input_lengths,
            ref_s[:, 128:],
            speed,
        )
        del pred_dur_int

        t_en = self.text_encoder(input_ids, input_lengths).to(dtype=self.model_dtype)
        asr = t_en @ alignment
        audio = self.decoder(asr, f0, noise, ref_s[:, :128], frame_lengths)
        return audio, pred_dur_float
