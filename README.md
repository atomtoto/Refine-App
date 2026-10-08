# Refine
Refine is an iOS app that enhances and restores music quality from your audio files. Made with SwiftUI ❤️

## Ce que fait l'app

- **Analyse du spectre** : détecte la coupure laissée par l'encodeur (≈ 16–17 kHz à 128 kbps), estime le débit d'origine et repère les « faux lossless » (FLAC/WAV issus d'un MP3).
- **Restauration on-device** (Accelerate/vDSP, aucune donnée envoyée) :
  - réparation des crêtes écrêtées (interpolation de Hermite) ;
  - comblement des trous spectraux dus à la quantification MP3 ;
  - reconstruction des aigus par réplication de bande (SBR), avec une pente extrapolée du spectre réel ;
  - conversion 16 bits / 44,1 kHz avec dither TPDF, export ALAC ou WAV.
- **Comparaison** : spectrogramme avant/après avec séparateur glissable, écoute A/B synchronisée sans coupure.

> Les données supprimées par la compression ne peuvent pas être récupérées à l'identique : Refine les reconstruit de façon plausible. Le protocole `RestorationEngine` permet de brancher plus tard un modèle Core ML (voir `NeuralRestorationEngine`).

## Développement

Xcode 27, iOS 27. Le projet utilise des dossiers synchronisés : tout fichier ajouté sous `Refine/` ou `RefineTests/` est compilé automatiquement.

```bash
xcodebuild -project Refine.xcodeproj -scheme Refine -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```
