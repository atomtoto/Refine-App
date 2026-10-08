"""Converts the Apollo MP3-restoration model (Kai Li & Yi Luo, CC BY-SA 4.0) to Core ML for Refine.

Apollo works on an STFT (n_fft 882 = 20 ms at 44.1 kHz, hop 441). The app computes the STFT, the per-band
normalisation and the log-power features in float32; this script exports only the network in between.

Apollo's 80 band-specific input and output layers are rewritten as batched matrix products: the first 79
bands share one width (5 bins) and run as a single batch, the last band (47 bins) on its own. The maths is
unchanged, but the graph shrinks from hundreds of small branches to a few large operations, which Core ML
compiles and schedules far better.

Model contract (one channel, fixed number of frames T):
  input  features [964, T]  per band b (in order), 2·w_b + 1 rows: real/p_b (w_b rows), imag/p_b (w_b rows),
                            log p_b (1 row), with p_b = sqrt(sum over the band's bins of real² + imag², plus eps)
  output real     [442, T]  restored spectrum
         imag     [442, T]
Band widths w_b and eps are stored in the model's metadata.

Usage: see README.md next to this file.
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn


def load_apollo(apollo_src: Path, checkpoint: Path):
    sys.path.insert(0, str(apollo_src))
    from look2hear.models.apollo import Apollo

    conf = torch.load(checkpoint, map_location="cpu", weights_only=False)
    args = dict(conf["model_args"])
    model = Apollo(**args)
    model.load_state_dict(conf["state_dict"])
    return model.eval(), args


class BatchedApollo(nn.Module):
    """Apollo between its feature extraction and its iSTFT, with band-specific layers batched."""

    def __init__(self, apollo):
        super().__init__()
        self.widths = [int(w) for w in apollo.band_width]
        narrow, wide = self.widths[0], self.widths[-1]
        assert all(w == narrow for w in self.widths[:-1]), "expected uniform bands plus one wide band"
        self.narrow_bands = len(self.widths) - 1
        self.narrow, self.wide = narrow, wide

        def head(b):
            rms, conv = apollo.BN[b][0], apollo.BN[b][1]
            return rms.weight, conv.weight[:, :, 0], conv.bias

        def tail(b):
            rms, conv = apollo.output[b][0], apollo.output[b][1]
            return rms.weight, conv.weight[:, :, 0], conv.bias

        heads = [head(b) for b in range(self.narrow_bands)]
        self.register_buffer("narrow_norm_in", torch.stack([h[0] for h in heads]).unsqueeze(-1))   # [79, 11, 1]
        self.register_buffer("narrow_weight_in", torch.stack([h[1] for h in heads]))               # [79, 256, 11]
        self.register_buffer("narrow_bias_in", torch.stack([h[2] for h in heads]).unsqueeze(-1))   # [79, 256, 1]
        norm, weight, bias = head(self.narrow_bands)
        self.register_buffer("wide_norm_in", norm.reshape(-1, 1))                                  # [95, 1]
        self.register_buffer("wide_weight_in", weight)                                             # [256, 95]
        self.register_buffer("wide_bias_in", bias.reshape(-1, 1))

        tails = [tail(b) for b in range(len(self.widths))]
        self.register_buffer("norm_out", torch.stack([t[0] for t in tails]).unsqueeze(-1))         # [80, 256, 1]
        self.register_buffer("narrow_weight_out", torch.stack([t[1] for t in tails[:-1]]))         # [79, 20, 256]
        self.register_buffer("narrow_bias_out", torch.stack([t[2] for t in tails[:-1]]).unsqueeze(-1))
        self.register_buffer("wide_weight_out", tails[-1][1])                                      # [188, 256]
        self.register_buffer("wide_bias_out", tails[-1][2].reshape(-1, 1))
        self.net = apollo.net
        self.eps = 1e-5  # Apollo's RMSNorm epsilon

    def rms_norm(self, x, weight, dim):
        return x * torch.rsqrt((x * x).mean(dim, keepdim=True) + self.eps) * weight

    def forward(self, features):
        frames = features.shape[-1]
        split = self.narrow_bands * (2 * self.narrow + 1)
        narrow = features[:split].reshape(self.narrow_bands, 2 * self.narrow + 1, frames)
        wide = features[split:]
        narrow = torch.matmul(self.narrow_weight_in, self.rms_norm(narrow, self.narrow_norm_in, 1)) + self.narrow_bias_in
        wide = torch.matmul(self.wide_weight_in, self.rms_norm(wide, self.wide_norm_in, 0)) + self.wide_bias_in
        hidden = torch.cat([narrow, wide.unsqueeze(0)], 0)                              # [80, 256, T]
        hidden = self.net(hidden.unsqueeze(0)).squeeze(0)
        hidden = self.rms_norm(hidden, self.norm_out, 1)

        narrow = torch.matmul(self.narrow_weight_out, hidden[:-1]) + self.narrow_bias_out  # [79, 20, T]
        narrow = narrow[:, :2 * self.narrow] * torch.sigmoid(narrow[:, 2 * self.narrow:])   # GLU -> [79, 10, T]
        wide = torch.matmul(self.wide_weight_out, hidden[-1]) + self.wide_bias_out          # [188, T]
        wide = wide[:2 * self.wide] * torch.sigmoid(wide[2 * self.wide:])                   # GLU -> [94, T]
        real = torch.cat([narrow[:, :self.narrow].reshape(-1, frames), wide[:self.wide]], 0)
        imag = torch.cat([narrow[:, self.narrow:].reshape(-1, frames), wide[self.wide:]], 0)
        return real, imag


def stft(apollo, audio: torch.Tensor) -> torch.Tensor:
    return torch.stft(audio, n_fft=apollo.win, hop_length=apollo.stride,
                      window=torch.hann_window(apollo.win), return_complex=True)


def istft(apollo, spec: torch.Tensor, length: int) -> torch.Tensor:
    return torch.istft(spec, n_fft=apollo.win, hop_length=apollo.stride,
                       window=torch.hann_window(apollo.win), length=length)


def pack_features(widths, spec: torch.Tensor, eps: float) -> torch.Tensor:
    """Reference implementation of `ApolloModel.fillFeatures` in the app. `spec`: [bins, T] complex."""
    rows, start = [], 0
    for w in widths:
        r, i = spec.real[start:start + w], spec.imag[start:start + w]
        power = torch.sqrt((r * r + i * i).sum(0, keepdim=True) + eps)
        rows += [r / power, i / power, torch.log(power)]
        start += w
    return torch.cat(rows, 0)


PRECISIONS = ("mixed", "float32", "float16")


def compute_precision(name: str):
    import coremltools as ct
    if name == "float32":
        return ct.precision.FLOAT32
    if name == "float16":
        return ct.precision.FLOAT16
    # Residual sums and normalisations exceed float16's range on loud music; matrix products don't.
    keep_float32 = {"add", "mul", "pow", "reduce_mean", "reduce_sum", "rsqrt", "real_div", "sub"}
    return ct.transform.FP16ComputePrecision(op_selector=lambda op: op.op_type not in keep_float32)


def snr(reference: np.ndarray, estimate: np.ndarray) -> float:
    noise = np.sum((reference - estimate) ** 2)
    return float(10 * np.log10(np.sum(reference ** 2) / max(noise, 1e-30)))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--apollo-src", type=Path, required=True, help="clone of github.com/JusperLee/Apollo")
    parser.add_argument("--checkpoint", type=Path, required=True, help="pytorch_model.bin from JusperLee/Apollo")
    parser.add_argument("--frames", type=int, default=256, help="STFT frames per prediction (fixed shape)")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--probe-audio", type=Path, help="44.1 kHz audio used to check the conversion")
    parser.add_argument("--reference-output", type=Path,
                        help="write PyTorch Apollo's output for --probe-audio here, as a test fixture")
    parser.add_argument("--precision", choices=PRECISIONS, default="mixed",
                        help="mixed: float16 matrix products, float32 normalisation and residual sums")
    parser.add_argument("--skip-check-units", action="store_true", help="only check Core ML on the CPU")
    args = parser.parse_args()

    import coremltools as ct

    apollo, model_args = load_apollo(args.apollo_src, args.checkpoint)
    network = BatchedApollo(apollo).eval()
    widths, frames = network.widths, args.frames
    samples = (frames - 1) * apollo.stride  # torch.stft(center=True) yields 1 + samples // hop frames

    if args.probe_audio:
        import soundfile as sf
        audio, rate = sf.read(args.probe_audio, dtype="float32", always_2d=True)
        assert rate == 44_100, "probe audio must be 44.1 kHz"
        probe = torch.from_numpy(np.ascontiguousarray(audio[:samples, 0]))
    else:
        probe = torch.randn(samples) * 0.1

    with torch.no_grad():
        features = pack_features(widths, stft(apollo, probe), apollo.eps)
        real, imag = network(features)
        rebuilt = istft(apollo, torch.complex(real, imag), samples)
        original = apollo(probe[None, None])[0, 0]
        print(f"batched network vs original Apollo: {snr(original.numpy(), rebuilt.numpy()):.1f} dB SNR", flush=True)
        exported = torch.export.export(network, (features,)).run_decompositions({})

    model = ct.convert(
        exported,
        inputs=[ct.TensorType(name="features", shape=tuple(features.shape), dtype=np.float32)],
        outputs=[ct.TensorType(name="real", dtype=np.float32), ct.TensorType(name="imag", dtype=np.float32)],
        convert_to="mlprogram",
        compute_precision=compute_precision(args.precision),
        minimum_deployment_target=ct.target.iOS18,
        compute_units=ct.ComputeUnit.CPU_ONLY,  # skip the slow Neural Engine compile while converting
    )
    model.author = "Kai Li, Yi Luo (Apollo); Core ML conversion for Refine"
    model.license = "CC BY-SA 4.0 — https://github.com/JusperLee/Apollo"
    model.short_description = "Apollo band-sequence network for restoring MP3-compressed music (44.1 kHz)."
    model.user_defined_metadata.update({
        "frames": str(frames),
        "n_fft": str(apollo.win),
        "hop": str(apollo.stride),
        "band_widths": ",".join(str(w) for w in widths),
        "eps": repr(float(apollo.eps)),
        "model_args": repr(dict(model_args)),
    })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    model.save(str(args.output))
    print(f"saved {args.output}", flush=True)

    # Core ML (float16) against PyTorch (float32), measured on the resynthesised waveform.
    import time
    units = [ct.ComputeUnit.CPU_ONLY] + ([] if args.skip_check_units else [ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.ALL])
    for unit in units:
        start = time.time()
        loaded = ct.models.MLModel(str(args.output), compute_units=unit)
        load_time = time.time() - start
        loaded.predict({"features": features.numpy()})
        start = time.time()
        prediction = loaded.predict({"features": features.numpy()})
        run_time = time.time() - start
        estimate = istft(apollo, torch.complex(torch.from_numpy(prediction["real"]), torch.from_numpy(prediction["imag"])), samples)
        print(f"Core ML {unit.name:12} load {load_time:6.1f} s, predict {run_time * 1000:6.0f} ms "
              f"({frames} frames), waveform SNR {snr(rebuilt.numpy(), estimate.numpy()):.1f} dB", flush=True)

    if args.probe_audio and args.reference_output:
        import soundfile as sf
        audio, _ = sf.read(args.probe_audio, dtype="float32", always_2d=True)
        with torch.no_grad():
            restored = apollo(torch.from_numpy(np.ascontiguousarray(audio.T))[None])[0].numpy()
        sf.write(args.reference_output, restored.T, 44_100, subtype="PCM_16")
        print(f"wrote reference {args.reference_output}", flush=True)


if __name__ == "__main__":
    main()
