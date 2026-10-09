import SwiftUI

struct RestoreSettingsView: View {
    @State var settings: RestorationSettings
    var analysis: AudioAnalysis?
    var onRestore: (RestorationSettings) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Moteur", selection: $settings.engine) {
                        ForEach(RestorationSettings.Engine.allCases) { engine in
                            Label {
                                Text(engine.title)
                                Text(engine.detail).font(.footnote)
                            } icon: {
                                Image(systemName: engine.systemImage)
                            }
                            .tag(engine)
                            .disabled(!engine.isAvailable)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()

                    if settings.engine == .apollo {
                        Picker("Calcul", selection: $settings.computeUnits) {
                            ForEach(RestorationSettings.ComputeUnits.allCases) { units in
                                Text(units.title).tag(units)
                            }
                        }
                    }
                } header: {
                    Text("Moteur")
                } footer: {
                    if settings.engine == .apollo {
                        Text("Apollo, par Kai Li et Yi Luo (Université Tsinghua, Tencent AI Lab), sous licence [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/deed.fr). [Code source et article](https://github.com/JusperLee/Apollo). Tout se passe sur l'iPhone : rien n'est envoyé en ligne.")
                    }
                }

                Section {
                    Picker("Préréglage", selection: $settings.preset) {
                        ForEach(RestorationSettings.Preset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: settings.preset) { _, preset in
                        settings.intensity = preset.intensity
                    }

                    LabeledContent("Dosage") {
                        Slider(value: $settings.intensity, in: 0.1...1) {
                            Text("Dosage")
                        } minimumValueLabel: {
                            Image(systemName: "speaker.wave.1")
                        } maximumValueLabel: {
                            Image(systemName: "sparkles")
                        }
                    }
                } header: {
                    Text("Intensité")
                } footer: {
                    Text("Dose les finitions et le remastering. « Subtil » reste au plus près de l'original.")
                }

                Section {
                    Toggle(isOn: $settings.extendBandwidth) {
                        Label {
                            Text(settings.engine == .apollo ? "Renforcer les aigus reconstruits" : "Reconstruire les aigus")
                            Text(extendDetail).font(.footnote)
                        } icon: {
                            Image(systemName: "arrow.up.and.down.text.horizontal")
                        }
                    }
                    if settings.engine == .signal {
                        Toggle(isOn: $settings.fillSpectralHoles) {
                            Label {
                                Text("Combler les trous du spectre")
                                Text("Adoucit le son « métallique » des MP3 à bas débit.").font(.footnote)
                            } icon: {
                                Image(systemName: "square.grid.3x3.bottomright.filled")
                            }
                        }
                    }
                    Toggle(isOn: $settings.restoreTransients) {
                        Label {
                            Text("Raviver les attaques")
                            Text("Retire le souffle de pré-écho qui précède les percussions.").font(.footnote)
                        } icon: {
                            Image(systemName: "waveform.badge.plus")
                        }
                    }
                    Toggle(isOn: $settings.restoreStereo) {
                        Label {
                            Text("Restaurer l'espace stéréo")
                            Text(stereoDetail).font(.footnote)
                        } icon: {
                            Image(systemName: "arrow.left.and.right")
                        }
                    }
                    Toggle(isOn: $settings.declip) {
                        Label {
                            Text("Réparer la saturation")
                            Text(declipDetail).font(.footnote)
                        } icon: {
                            Image(systemName: "waveform.path.ecg")
                        }
                    }
                } header: {
                    Text("Étapes")
                } footer: {
                    if settings.engine == .apollo {
                        Text("Apollo reconstruit les aigus et corrige les artefacts sur tout le spectre ; les étapes ci-dessus finissent le travail.")
                    }
                }

                Section {
                    Toggle(isOn: $settings.rebalanceTone) {
                        Label {
                            Text("Rééquilibrer le son")
                            Text(toneDetail).font(.footnote)
                        } icon: {
                            Image(systemName: "slider.vertical.3")
                        }
                    }
                    Toggle(isOn: $settings.restorePunch) {
                        Label {
                            Text("Redonner du punch")
                            Text(punchDetail).font(.footnote)
                        } icon: {
                            Image(systemName: "bolt")
                        }
                    }
                    Toggle(isOn: $settings.adjustLoudness) {
                        Label {
                            Text("Ajuster le volume")
                            Text(loudnessDetail).font(.footnote)
                        } icon: {
                            Image(systemName: "speaker.wave.2")
                        }
                    }
                } header: {
                    Text("Remasteriser")
                } footer: {
                    Text("Seuls les défauts détectés sont corrigés : un morceau déjà bien masterisé ressort tel quel.")
                }

                Section {
                    Picker("Format", selection: $settings.exportFormat) {
                        ForEach(RestorationSettings.ExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    LabeledContent("Résolution", value: settings.exportFormat.summary)
                } header: {
                    Text("Export")
                } footer: {
                    Text("ALAC et WAV sont sans perte, en qualité CD. AAC 256 kbps est le format d'Apple Music et celui qu'utilisent les AirPods en Bluetooth : 4 à 5 fois plus léger, sans différence audible au casque.\n\nLes données supprimées par la compression ne peuvent pas être récupérées à l'identique : Refine les reconstruit de façon plausible à partir de ce qui reste.")
                }
            }
            .navigationTitle("Restauration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Restaurer", systemImage: "wand.and.sparkles", role: .confirm) {
                        onRestore(settings)
                        dismiss()
                    }
                }
            }
        }
    }

    private var extendDetail: String {
        guard let analysis else { return "Prolonge le spectre au-delà de la coupure." }
        guard analysis.hasMissingHighs else { return "Rien à reconstruire : le spectre est déjà complet." }
        return settings.engine == .apollo
            ? "Ramène les aigus recréés au-delà de \(analysis.cutoffFrequency.kilohertz) à un niveau naturel."
            : "De \(analysis.cutoffFrequency.kilohertz) jusqu'à \(SpectralRestorer.Parameters.targetTop.kilohertz)."
    }

    private var stereoDetail: String {
        guard let stereo = analysis?.stereo else { return "Rouvre l'image si l'encodeur l'a resserrée dans les aigus." }
        switch stereo.kind {
        case .collapsed:
            return "Image resserrée au-dessus de \(stereo.collapseFrequency?.kilohertz ?? "6 kHz") : elle sera rouverte."
        case .intact:
            return "Image stéréo intacte : rien à corriger."
        case .mono:
            return "Fichier mono : rien à élargir."
        }
    }

    private var toneDetail: String {
        guard let tonal = analysis?.tonal else { return "Corrige un son sourd, trop chargé en grave ou confus." }
        switch tonal.kind {
        case .dull: return "Son sourd : \((-tonal.presenceOffset).decibels) de présence en moins qu'un master actuel."
        case .bright: return "Son plus brillant que la moyenne : les aigus seront légèrement adoucis."
        case .heavy: return "Grave ou bas-médium en excès : ils seront allégés."
        case .thin: return "Grave en retrait : il sera renforcé."
        case .balanced: return "Équilibre déjà naturel : rien à corriger."
        }
    }

    private var punchDetail: String {
        guard let loudness = analysis?.loudness else { return "Rend leurs attaques aux morceaux trop compressés." }
        return loudness.kind == .squashed
            ? "Master écrasé (crête à \(loudness.crest.decibels) du niveau moyen) : les attaques seront ravivées."
            : "Dynamique préservée : rien à raviver."
    }

    private var loudnessDetail: String {
        guard let loudness = analysis?.loudness else { return "Remonte un morceau trop faible et protège les crêtes." }
        switch loudness.kind {
        case .weak:
            return "Morceau faible (\(Int(loudness.integrated.rounded())) LUFS) : remonté vers \(Int(LoudnessProfile.targetLoudness)) LUFS, crêtes limitées à −1 dBTP."
        case .squashed:
            return "Baisse légèrement le volume pour laisser place aux attaques ; crêtes limitées à −1 dBTP."
        case .natural:
            return "Volume conservé ; crêtes limitées à −1 dBTP."
        }
    }

    private var declipDetail: String {
        guard let analysis else { return "Redessine les crêtes écrêtées." }
        return analysis.isClipped ? "Des crêtes écrêtées ont été détectées." : "Aucune saturation détectée."
    }
}

extension RestorationSettings.Engine {
    var detail: String {
        switch self {
        case .signal: "Instantané et léger : prolonge le spectre en recopiant les harmoniques existantes."
        case .apollo: isAvailable
            ? "Réseau de neurones entraîné à restaurer les MP3. Plus lent, plus naturel."
            : "Modèle non inclus dans cette version."
        }
    }

    var systemImage: String {
        switch self {
        case .signal: "waveform.path"
        case .apollo: "brain"
        }
    }
}
