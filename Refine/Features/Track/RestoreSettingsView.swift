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
                    Text("Règle le niveau des aigus reconstruits. « Subtil » reste au plus près de l'original.")
                }

                Section {
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
                }

                Section {
                    Picker("Format", selection: $settings.exportFormat) {
                        ForEach(RestorationSettings.ExportFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    LabeledContent("Résolution", value: "16 bits · 44,1 kHz · stéréo")
                    LabeledContent("Moteur", value: DSPRestorationEngine().name)
                    LabeledContent("IA neuronale", value: NeuralRestorationEngine.isAvailable ? "Disponible" : "Bientôt")
                } header: {
                    Text("Export")
                } footer: {
                    Text("Les données supprimées par la compression ne peuvent pas être récupérées à l'identique : Refine les reconstruit de façon plausible à partir de ce qui reste, puis exporte au format CD.")
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
