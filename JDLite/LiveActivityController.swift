import ActivityKit
import Combine
import Foundation
import UIKit

/// Shows overall download progress as one Live Activity (Lock Screen and Dynamic Island).
@MainActor
final class LiveActivityController {
    static let shared = LiveActivityController()

    typealias State = DownloadActivityAttributes.ContentState

    private var activity: Activity<DownloadActivityAttributes>?
    private var batch = Set<UUID>()          // downloads counted in the current activity
    private var lastState: State?
    private var lastUpdate = Date.distantPast
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        activity = Activity<DownloadActivityAttributes>.activities.first   // left over from a previous run
        let manager = DownloadManager.shared
        manager.$items
            .combineLatest(manager.$speeds)
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            .store(in: &cancellables)
        // Hand iOS a self-advancing bar when the app goes to sleep, and catch up when it's back.
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh(force: true) }
            }
            .store(in: &cancellables)
    }

    func refresh(force: Bool = false) async {
        let manager = DownloadManager.shared
        let items = manager.items

        guard AppSettings.shared.liveActivityEnabled, ActivityAuthorizationInfo().areActivitiesEnabled else {
            if let current = activity {
                activity = nil
                lastState = nil
                batch.removeAll()
                await current.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        let running = items.filter { $0.state == .downloading || $0.state == .resolving || $0.state == .queued }
        if activity == nil { batch.removeAll() }
        batch.formUnion(running.map(\.id))
        let tracked = items.filter { batch.contains($0.id) }

        guard !running.isEmpty else {
            if let current = activity {
                let (state, policy) = finalState(tracked: tracked)
                activity = nil
                lastState = nil
                batch.removeAll()
                await current.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy)
            }
            return
        }

        let state = makeState(running: running, tracked: tracked, speeds: manager.speeds)
        if let current = activity {
            guard force || shouldUpdate(to: state) else { return }
            lastState = state
            lastUpdate = Date()
            await current.update(ActivityContent(state: state, staleDate: nil))
        } else if UIApplication.shared.applicationState != .background {
            // iOS only lets an app start a Live Activity while it's open.
            do {
                activity = try Activity<DownloadActivityAttributes>.request(
                    attributes: DownloadActivityAttributes(),
                    content: ActivityContent(state: state, staleDate: nil),
                    pushType: nil)
                lastState = state
                lastUpdate = Date()
            } catch {
                // Live Activities are off for the app, or too many are running: skip it.
            }
        }
    }

    private func shouldUpdate(to state: State) -> Bool {
        guard let last = lastState else { return true }
        if last.phase != state.phase || last.title != state.title || last.count != state.count { return true }
        let elapsed = Date().timeIntervalSince(lastUpdate)
        if abs(last.progress - state.progress) >= 0.01 && elapsed >= 2 { return true }
        return elapsed >= 10 && state != last
    }

    private func makeState(running: [DownloadItem], tracked: [DownloadItem], speeds: [UUID: Double]) -> State {
        let downloading = running.filter { $0.state == .downloading }
        let fetching = running.filter { $0.state == .resolving && ($0.torboxId != nil || $0.offcloudId != nil) }
        let speed = downloading.reduce(0.0) { $0 + (speeds[$1.id] ?? 0) }
        let sized = tracked.filter { $0.bytesTotal > 0 }
        let total = sized.reduce(Int64(0)) { $0 + $1.bytesTotal }
        let done = sized.reduce(Int64(0)) { $0 + min($1.bytesReceived, $1.bytesTotal) }
        let title = running.count == 1 ? running[0].fileName : "\(running.count) downloads"

        if downloading.isEmpty, let first = fetching.first {
            let services = Set(fetching.compactMap { $0.serviceName })
            let who = services.count == 1 ? (services.first ?? "TorBox") : "TorBox and Offcloud"
            let detail = fetching.count == 1 ? "\(who) is fetching the file" : "\(who) \(services.count == 1 ? "is" : "are") fetching \(fetching.count) files"
            return State(phase: .fetching, title: title, detail: detail,
                         progress: first.cloudProgress ?? 0, count: running.count)
        }

        let progress = total > 0 ? min(Double(done) / Double(total), 1) : 0
        var parts = [total > 0 ? "\(Fmt.bytes(done)) of \(Fmt.bytes(total))" : Fmt.bytes(done)]
        if speed > 0 { parts.append(Fmt.speed(speed)) }
        var state = State(phase: .downloading, title: title, detail: parts.joined(separator: " · "),
                          progress: progress, count: running.count)
        if speed > 0, total > done, progress > 0.001, progress < 1 {
            let remaining = Double(total - done) / speed
            if remaining < 86_400 {
                // Dates chosen so the bar shows the current progress now and reaches 100% at the estimated finish.
                let now = Date()
                state.timerEnd = now.addingTimeInterval(remaining)
                state.timerStart = now.addingTimeInterval(-progress * remaining / (1 - progress))
            }
        }
        return state
    }

    private func finalState(tracked: [DownloadItem]) -> (State, ActivityUIDismissalPolicy) {
        let finished = tracked.filter { $0.state == .completed }
        let failed = tracked.filter { $0.state == .failed }
        if !failed.isEmpty {
            let title = failed.count == 1 ? failed[0].fileName : "\(failed.count) downloads failed"
            let detail = failed.count == 1 ? (failed[0].error ?? "Download failed") : "Open JDLite to retry them"
            return (State(phase: .failed, title: title, detail: detail,
                          progress: lastState?.progress ?? 0, count: failed.count),
                    .after(Date().addingTimeInterval(15 * 60)))
        }
        if !finished.isEmpty {
            let bytes = finished.reduce(Int64(0)) { $0 + $1.bytesTotal }
            let title = finished.count == 1 ? finished[0].fileName : "\(finished.count) downloads finished"
            let detail = finished.count == 1 ? "Finished · \(Fmt.bytes(bytes))" : "\(Fmt.bytes(bytes)) downloaded"
            return (State(phase: .finished, title: title, detail: detail, progress: 1, count: finished.count),
                    .after(Date().addingTimeInterval(5 * 60)))
        }
        // Everything was paused or removed: take the activity away.
        var paused = lastState ?? State(phase: .paused, title: "Downloads paused", detail: "", progress: 0, count: 0)
        paused.phase = .paused
        paused.timerStart = nil
        paused.timerEnd = nil
        return (paused, .immediate)
    }
}
