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
                    Text(settings.engine == .apollo
                        ? "Part du son restauré par l'IA, mélangé à l'original. « Subtil » reste au plus près de l'original."
                        : "Règle le niveau des aigus reconstruits. « Subtil » reste au plus près de l'original.")
                }

                Section {
                    if settings.engine == .signal {
                        Toggle(isOn: $settings.extendBandwidth) {
                            Label {
                                Text("Reconstruire les aigus")
                                Text(extendDetail).font(.footnote)
                            } icon: {
                                Image(systemName: "arrow.up.and.down.text.horizontal")
                            }
                        }
                        Toggle(isOn: $settings.fillSpectralHoles) {
                            Label {
                                Text("Combler les trous du spectre")
                                Text("Adoucit le son « métallique » des MP3 à bas débit.").font(.footnote)
                            } icon: {
                                Image(systemName: "square.grid.3x3.bottomright.filled")
                            }
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
                        Text("Apollo reconstruit lui-même les aigus et corrige les artefacts de compression sur tout le spectre.")
                    }
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
        return analysis.hasMissingHighs
            ? "De \(analysis.cutoffFrequency.kilohertz) jusqu'à \(SpectralRestorer.Parameters.targetTop.kilohertz)."
            : "Rien à reconstruire : le spectre est déjà complet."
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
