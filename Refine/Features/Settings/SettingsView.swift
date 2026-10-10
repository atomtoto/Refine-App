import SwiftUI

struct SettingsView: View {
    @State private var icon = AppIcon.current
    @State private var iconError: String?
    @ScaledMetric(relativeTo: .body) private var previewSize = 60

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Icône de l'app") {
                    Picker("Icône de l'app", selection: $icon) {
                        ForEach(AppIcon.allCases) { icon in
                            // An HStack rather than a Label: a list row sizes Label icons for SF Symbols.
                            HStack(spacing: 14) {
                                Image(icon.preview)
                                    .resizable()
                                    .frame(width: previewSize, height: previewSize)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading) {
                                    Text(icon.title)
                                    Text(icon.detail)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .tag(icon)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
            }
            .navigationTitle("Réglages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK", systemImage: "checkmark", role: .confirm) { dismiss() }
                }
            }
            .onChange(of: icon) { _, icon in
                Task {
                    do {
                        try await icon.apply()
                    } catch {
                        iconError = error.localizedDescription
                        self.icon = .current
                    }
                }
            }
            .alert(
                "Impossible de changer l'icône",
                isPresented: Binding(get: { iconError != nil }, set: { if !$0 { iconError = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(iconError ?? "")
            }
        }
    }
}

#Preview {
    SettingsView()
}
