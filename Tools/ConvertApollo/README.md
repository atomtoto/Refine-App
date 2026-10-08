# Apollo → Core ML

Produces `Refine/MachineLearning/RefineApollo.mlpackage`, the neural engine behind « IA Apollo ».

[Apollo](https://github.com/JusperLee/Apollo) (Kai Li & Yi Luo, CC BY-SA 4.0) restores MP3-compressed music
(24–128 kbps) to full-band 44.1 kHz audio. The app runs it on-device; nothing is sent online.

## What the script exports

Only the network between Apollo's feature extraction and its iSTFT. The app computes, in float32:

- the STFT (882-point periodic Hann, hop 441, centred with reflect padding, like `torch.stft`): `MatrixSTFT`
- the per-band features (normalised real/imaginary parts + log power): `ApolloModel.fillFeatures`
- the block scheduling (384 frames per prediction, 48 frames of context each side, the last block anchored
  to the end of the file) and the overlap-add resynthesis: `SpectralBlockProcessor`

Apollo's 80 band-specific layers are rewritten as batched matrix products (79 bands of 5 bins + 1 band of 47),
which keeps the maths identical (≈ 125 dB SNR against the original) but makes the graph small enough for Core ML.

Precision is mixed: matrix products in float16, normalisations and residual sums in float32 (they exceed
float16's range on loud music). The Neural Engine is not used: it is float16-only, and compiling this model
for it takes minutes on first load.

## Measured accuracy (4 s of a 128 kbps MP3, against PyTorch Apollo on the whole file)

| Where                                   | SNR       |
|-----------------------------------------|-----------|
| Batched network vs original, PyTorch    | 125 dB    |
| Core ML, one block, GPU / CPU           | 58 / 47 dB |
| Full app pipeline (Python emulation)    | 57 dB     |

## Reproduce

```bash
python3.11 -m venv .venv && .venv/bin/pip install -r Tools/ConvertApollo/requirements.txt
git clone https://github.com/JusperLee/Apollo.git /tmp/apollo-src
curl -L -o /tmp/apollo.bin https://huggingface.co/JusperLee/Apollo/resolve/main/pytorch_model.bin
.venv/bin/python Tools/ConvertApollo/convert_apollo.py \
    --apollo-src /tmp/apollo-src --checkpoint /tmp/apollo.bin --frames 384 --precision mixed \
    --output Refine/MachineLearning/RefineApollo.mlpackage \
    --probe-audio RefineTests/apollo-probe.wav --reference-output RefineTests/apollo-reference.wav
```

The checkpoint used for the bundled model has SHA-256
`99d9af7f1ff20e63c393035513a655392818d66b4d7fc23d658175c1f15e8d76`. `RefineTests/apollo-probe.wav` is a 4 s
excerpt of a 128 kbps MP3; `apollo-reference.wav` is PyTorch Apollo's output on it, checked by `ApolloTests`.
