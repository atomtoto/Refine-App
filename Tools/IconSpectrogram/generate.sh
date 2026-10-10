#!/bin/zsh
# Regenerates the spectrogram layers of Refine/AppIcon.icon. Needs lame and ffmpeg (brew install lame ffmpeg).
set -euo pipefail
here=${0:A:h}
assets=$here/../../Refine/AppIcon.icon/Assets
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

swiftc -O "$here/synth.swift" -o "$work/synth"
swiftc -O "$here/spectrogram.swift" -o "$work/spectrogram"
"$work/synth" "$work/source.wav"
# A real low-bitrate MP3: LAME's 12.5 kHz low-pass puts the cut-off just above mid-height on the linear axis.
lame --quiet -b 96 --resample 44.1 --lowpass 12.5 "$work/source.wav" "$work/clip.mp3"
ffmpeg -loglevel error -y -i "$work/clip.mp3" "$work/decoded.wav"
"$work/spectrogram" "$work/source.wav" "$work/decoded.wav" "$assets/Spectrogram.png" "$assets/SpectrogramMono.png"
