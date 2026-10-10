# Icon spectrogram

Generates the background of `Refine/AppIcon.icon`: a real spectrogram, computed the way the app draws its own.

1. `synth.swift` synthesizes one bar of music (kick, snare, hi-hats, 808, chords, a sung lead with vibrato).
2. LAME encodes it as a 96 kbps MP3 with an 11 kHz low-pass, and ffmpeg decodes it back.
3. `spectrogram.swift` runs an STFT on both (2048-point Hann, linear frequency axis up to 22.05 kHz) and paints
   them with the palette of `SpectrogramRenderer`: the MP3 on the left, with its hard ceiling, the full-band source
   on the right, like the before/after divider of the track screen.

```bash
brew install lame ffmpeg
Tools/IconSpectrogram/generate.sh
```

It writes `Spectrogram.png` and `SpectrogramMono.png` (used by the tinted appearances) into the icon's assets.
The other layers (divider, knob, chevrons, cut-off dots) are SVGs edited in Icon Composer.
The previous icon is kept as the alternate `Refine/AppIconClassic.icon`.
