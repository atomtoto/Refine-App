# Refine
Refine is an iOS app that enhances and restores music quality from your audio files. Made with SwiftUI ❤️

## Ce que fait l'app

- **Analyse du spectre** : détecte la coupure laissée par l'encodeur (≈ 16–17 kHz à 128 kbps), estime le débit d'origine, repère les « faux lossless » (FLAC/WAV issus d'un MP3) et mesure la largeur stéréo.
- **Diagnostic du master** : sonie et true peak (ITU-R BS.1770 / EBU R 128), punch (crête/RMS), et équilibre tonal comparé à la moyenne de masters actuels (sourd, chargé en grave, maigre…).
- **Deux moteurs, 100 % sur l'iPhone** (aucune donnée envoyée, aucun compte) :
  - **IA Apollo** (par défaut) : réseau de neurones [Apollo](https://github.com/JusperLee/Apollo) entraîné à restaurer
    les MP3 (24–128 kbps), converti en Core ML et exécuté sur le GPU. Reconstruit les aigus et corrige les artefacts
    de compression sur tout le spectre. Voir `Tools/ConvertApollo` et `THIRD_PARTY_NOTICES.md` (CC BY-SA 4.0).
  - **Traitement du signal** (Accelerate/vDSP), instantané :
    réparation des crêtes écrêtées, comblement des trous spectraux, reconstruction des aigus par réplication de bande.
- **Finitions** après chaque moteur, réglées sur le fichier et mesurées :
  - **Attaques** : retire le pré-écho, ce souffle que le MP3 étale juste avant les percussions ;
  - **Brillance** : ramène les aigus reconstruits au niveau que prédit la pente du spectre ;
  - **Espace** : rouvre l'image stéréo si l'encodeur l'a resserrée dans les aigus (rien n'est fait sinon).
- **Remastering**, seulement pour les défauts détectés (un bon master ressort tel quel) :
  - **Équilibre tonal** : redonne de la clarté à un son sourd, allège un grave ou un bas-médium en excès ;
  - **Punch** : rend leurs attaques aux masters écrasés par le limiteur (transient shaper sur trois bandes) ;
  - **Volume** : remonte un master trop faible vers −14 LUFS, avec un limiteur true peak à −1 dBTP.
- **Mix**, sans séparer les instruments :
  - **Voix** : curseur de −6 à +6 dB sur ce qui est au centre de l'image, là où la voix est mixée ;
  - **Grave resserré** : basse et grosse caisse en mono sous 120 Hz ;
  - **Sifflantes et duretés** (à activer à l'écoute) : de-esser et contrôle dynamique des médiums, qui ne visent que les pics extrêmes.
- **Export** 16 bits / 44,1 kHz avec dither TPDF : ALAC, WAV, ou AAC 256 kbps (le format d'Apple Music et des AirPods).
- **Comparaison** : spectrogramme avant/après avec séparateur glissable, écoute A/B synchronisée sans coupure et à volume égal, pour que la version la plus forte ne paraisse pas meilleure à tort. La lecture passe par `AVPlayer` : avec des AirPods, l'audio spatial (stéréo spatialisée, suivi de la tête) se règle depuis le centre de contrôle, et le morceau apparaît dans « À l'écoute » et sur l'écran verrouillé.
- **Activité en direct** : pendant une restauration, l'écran verrouillé et la Dynamic Island montrent le vinyle du morceau et un spectre qui s'allume des graves jusqu'aux aigus reconstruits. Refine continue quelques instants après avoir quitté l'app ; si iOS la suspend, l'activité passe « En pause » et la restauration reprend au retour dans l'app (extension `RefineWidgets`, données partagées dans `RefineShared`).

> Les données supprimées par la compression ne peuvent pas être récupérées à l'identique : Refine les reconstruit de façon plausible. D'autres moteurs peuvent être ajoutés derrière le protocole `RestorationEngine` ; un modèle spectral se branche via `SpectralModel` et `SpectralBlockProcessor`.

## Développement

Xcode 27, iOS 27. Le projet utilise des dossiers synchronisés : tout fichier ajouté sous `Refine/` ou `RefineTests/` est compilé automatiquement.

```bash
xcodebuild -project Refine.xcodeproj -scheme Refine -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test
```

L'icône est un document Icon Composer (`Refine/AppIcon.icon`) dont le fond est un vrai spectrogramme, généré par `Tools/IconSpectrogram`. L'ancienne icône reste proposée dans les Réglages de l'app (icône alternative `AppIconClassic`).
