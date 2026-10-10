import ActivityKit
import SwiftUI
import UIKit

/// Mirrors running restorations in Live Activities, and asks iOS for a little time to keep restoring once Refine
/// leaves the foreground. When that time runs out the activities say the work is paused; it resumes with the app.
@MainActor
final class RestorationActivities {
    typealias State = RestorationActivityAttributes.ContentState

    enum Outcome {
        case finished, failed, cancelled
    }

    private var running: Set<UUID> = []
    /// Activity identifiers: `Activity` isn't `Sendable`, so each update looks its activity up again.
    private var activities: [UUID: String] = [:]
    private var published: [UUID: (state: State, date: Date)] = [:]
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var suspended = false

    /// Without an update for this long, the activity shows the work as paused (the app was suspended or closed).
    private static let staleness: TimeInterval = 90

    init() {
        // Restorations don't survive a relaunch: close the activities a killed process left behind.
        let orphans = Activity<RestorationActivityAttributes>.activities.map(\.id)
        Task {
            for id in orphans { await Self.end(id, content: nil, dismissalPolicy: .immediate) }
        }
    }

    func start(for track: Track, engine: RestorationSettings.Engine) async {
        running.insert(track.id)
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attributes = RestorationActivityAttributes(
            title: track.title,
            artist: track.artist,
            engine: engine == .apollo ? .apollo : .signal,
            labelColors: await Self.labelColors(for: track))
        let state = State(phase: .restoring, fraction: 0, stage: .engine)
        // A bonus: the restoration runs the same without its Live Activity.
        guard running.contains(track.id),
              let activity = try? Activity.request(attributes: attributes, content: content(state))
        else { return }
        activities[track.id] = activity.id
        published[track.id] = (state, .now)
    }

    func update(_ id: UUID, fraction: Double, stage: RestorationProgress.Stage) {
        let state = State(
            phase: suspended ? .paused : .restoring, fraction: fraction, stage: stage == .engine ? .engine : .finishing)
        // Every percent at most twice a second, at least every 20 s so the activity doesn't go stale.
        if let last = published[id], last.state.phase == state.phase, last.state.stage == state.stage {
            let elapsed = Date.now.timeIntervalSince(last.date)
            if elapsed < 20, abs(last.state.fraction - fraction) < 0.01 || elapsed < 0.5 { return }
        }
        publish(state, for: id)
    }

    func end(_ id: UUID, outcome: Outcome) {
        running.remove(id)
        if running.isEmpty { endBackgroundTask() }
        guard let activity = activities.removeValue(forKey: id) else { return }
        let last = published.removeValue(forKey: id)?.state
        // In the app the result is already on screen; elsewhere it stays on the Lock Screen for a while.
        let dismissal: ActivityUIDismissalPolicy = UIApplication.shared.applicationState == .active
            ? .immediate : .after(.now.addingTimeInterval(15 * 60))
        let finalState: State? = switch outcome {
        case .finished: State(phase: .finished, fraction: 1, stage: .finishing)
        case .failed: State(phase: .failed, fraction: last?.fraction ?? 0, stage: last?.stage ?? .engine)
        case .cancelled: nil
        }
        Task {
            await Self.end(
                activity, content: finalState.map { ActivityContent(state: $0, staleDate: nil) },
                dismissalPolicy: finalState == nil ? .immediate : dismissal)
        }
    }

    // MARK: - App lifecycle

    func didEnterBackground() {
        guard !running.isEmpty, backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Restauration") { [weak self] in
            MainActor.assumeIsolated { self?.suspend() }
        }
    }

    func didBecomeActive() {
        endBackgroundTask()
        guard suspended else { return }
        suspended = false
        for (id, entry) in published {
            publish(State(phase: .restoring, fraction: entry.state.fraction, stage: entry.state.stage), for: id)
        }
    }

    /// iOS is about to suspend the app: say so on the Lock Screen before letting it.
    private func suspend() {
        suspended = true
        var contents: [(String, ActivityContent<State>)] = []
        for (id, entry) in published {
            let paused = State(phase: .paused, fraction: entry.state.fraction, stage: entry.state.stage)
            published[id] = (paused, .now)
            if let activity = activities[id] { contents.append((activity, content(paused))) }
        }
        Task {
            for (activity, content) in contents { await Self.update(activity, with: content) }
            endBackgroundTask()
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    // MARK: - Helpers

    private func publish(_ state: State, for id: UUID) {
        guard let activity = activities[id] else { return }
        published[id] = (state, .now)
        let content = content(state)
        Task { await Self.update(activity, with: content) }
    }

    private nonisolated static func activity(_ id: String) -> Activity<RestorationActivityAttributes>? {
        Activity<RestorationActivityAttributes>.activities.first { $0.id == id }
    }

    private nonisolated static func update(_ id: String, with content: ActivityContent<State>) async {
        await activity(id)?.update(content)
    }

    private nonisolated static func end(
        _ id: String, content: ActivityContent<State>?, dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        await activity(id)?.end(content, dismissalPolicy: dismissalPolicy)
    }

    private func content(_ state: State) -> ActivityContent<State> {
        ActivityContent(state: state, staleDate: .now.addingTimeInterval(Self.staleness))
    }

    /// The vinyl label's colours: the cover's diagonal, as on the record in the app, or the track's own hue.
    private static func labelColors(for track: Track) async -> [Color.Resolved] {
        let environment = EnvironmentValues()
        let colors = if let palette = await ArtworkPalette.colors(from: track.thumbnailData ?? track.artworkData) {
            [palette[0], palette[2]]
        } else {
            VinylView.labelColors(hue: VinylView.hue(for: track.id))
        }
        return colors.map { $0.resolve(in: environment) }
    }
}
