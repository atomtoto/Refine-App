import SwiftData
import SwiftUI

@main
struct RefineApp: App {
    @State private var processor = TrackProcessor()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(processor)
        }
        .modelContainer(for: Track.self)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: processor.didEnterBackground()
            case .active: processor.didBecomeActive()
            default: break
            }
        }
    }
}
