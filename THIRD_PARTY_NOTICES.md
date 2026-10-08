# Third-party notices

## Apollo — `Refine/MachineLearning/RefineApollo.mlpackage`

Apollo: Band-sequence Modeling for High-Quality Audio Restoration, by Kai Li and Yi Luo
(Tsinghua University, Tencent AI Lab). https://github.com/JusperLee/Apollo · https://arxiv.org/abs/2409.08514

The bundled Core ML model is a conversion of the official checkpoint
(`huggingface.co/JusperLee/Apollo`, `pytorch_model.bin`, SHA-256
`99d9af7f1ff20e63c393035513a655392818d66b4d7fc23d658175c1f15e8d76`), produced with
`Tools/ConvertApollo/convert_apollo.py`. The network weights are unchanged apart from float16 storage;
the STFT and feature extraction moved into the app (`ApolloModel.swift`).

Licensed under the Creative Commons Attribution-ShareAlike 4.0 International License
(https://creativecommons.org/licenses/by-sa/4.0/). As an adaptation, the converted model is distributed
under the same license.
