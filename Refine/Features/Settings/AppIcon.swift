import SwiftUI

/// Home Screen icons. The spectrogram is the primary icon; the original bars are kept as an alternate.
enum AppIcon: String, CaseIterable, Identifiable {
    case spectrogram
    case classic

    var id: Self { self }

    /// Name of the alternate `.icon` file, `nil` for the primary icon.
    var alternateIconName: String? {
        switch self {
        case .spectrogram: nil
        case .classic: "AppIconClassic"
        }
    }

    var title: String {
        switch self {
        case .spectrogram: "Spectrogramme"
        case .classic: "Classique"
        }
    }

    var detail: String {
        switch self {
        case .spectrogram: "Un vrai spectre, avant et après restauration."
        case .classic: "Les barres de spectre d'origine."
        }
    }

    var preview: ImageResource {
        switch self {
        case .spectrogram: .appIconPreview
        case .classic: .appIconClassicPreview
        }
    }

    @MainActor static var current: AppIcon {
        allCases.first { $0.alternateIconName == UIApplication.shared.alternateIconName } ?? .spectrogram
    }

    @MainActor func apply() async throws {
        guard UIApplication.shared.alternateIconName != alternateIconName else { return }
        try await UIApplication.shared.setAlternateIconName(alternateIconName)
    }
}
