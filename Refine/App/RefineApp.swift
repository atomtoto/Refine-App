import SwiftData
import SwiftUI

@main
struct RefineApp: App {
    @State private var processor = TrackProcessor()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(processor)
        }
        .modelContainer(for: Track.self)
    }
}
