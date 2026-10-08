# Refine
Refine is an iOS app that enhances and restores music quality from your audio files. Made with SwiftUI ❤️

## Ce que fait l'app

- **Analyse du spectre** : détecte la coupure laissée par l'encodeur (≈ 16–17 kHz à 128 kbps), estime le débit d'origine et repère les « faux lossless » (FLAC/WAV issus d'un MP3).
- **Deux moteurs, 100 % sur l'iPhone** (aucune donnée envoyée, aucun compte) :
  - **IA Apollo** (par défaut) : réseau de neurones [Apollo](https://github.com/JusperLee/Apollo) entraîné à restaurer
    les MP3 (24–128 kbps), converti en Core ML et exécuté sur le GPU. Reconstruit les aigus et corrige les artefacts
    de compression sur tout le spectre. Voir `Tools/ConvertApollo` et `THIRD_PARTY_NOTICES.md` (CC BY-SA 4.0).
  - **Traitement du signal** (Accelerate/vDSP), instantané :
    réparation des crêtes écrêtées, comblement des trous spectraux, reconstruction des aigus par réplication de bande.
- **Export** 16 bits / 44,1 kHz avec dither TPDF : ALAC, WAV, ou AAC 256 kbps (le format d'Apple Music et des AirPods).
- **Comparaison** : spectrogramme avant/après avec séparateur glissable, écoute A/B synchronisée sans coupure.

> Les données supprimées par la compression ne peuvent pas être récupérées à l'identique : Refine les reconstruit de façon plausible. D'autres moteurs peuvent être ajoutés derrière le protocole `RestorationEngine` ; un modèle spectral se branche via `SpectralModel` et `SpectralBlockProcessor`.

## Développement

Xcode 27, iOS 27. Le projet utilise des dossiers synchronisés : tout fichier ajouté sous `Refine/` ou `RefineTests/` est compilé automatiquement.

```bash
xcodebuild -project Refine.xcodeproj -scheme Refine -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```
