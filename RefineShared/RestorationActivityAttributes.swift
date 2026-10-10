import ActivityKit
import SwiftUI

/// The Live Activity shown while Refine restores a track. Compiled into both the app and the widget extension.
struct RestorationActivityAttributes: ActivityAttributes {
    enum Engine: String, Codable, Hashable {
        case signal, apollo
    }

    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case restoring
            /// iOS suspended the app: the work resumes when Refine comes back to the foreground.
            case paused
            case finished
            case failed
        }

        enum Stage: String, Codable, Hashable {
            /// The engine itself: band replication or the neural network.
            case engine
            /// Finishing stages: highs, stereo image, attacks.
            case finishing
        }

        var phase: Phase
        var fraction: Double
        var stage: Stage
    }

    var title: String
    var artist: String?
    var engine: Engine
    /// Colours of the vinyl's label: the cover's, or the track's own hue when it has none.
    var labelColors: [Color.Resolved]
}
