import ActivityKit
import Foundation

/// The Live Activity's data, shared by the app (which updates it) and the widget
/// extension (which draws it on the Lock Screen and in the Dynamic Island).
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case downloading, fetching, paused, finished, failed
        }

        var phase: Phase
        var title: String       // a file name, or "3 downloads"
        var detail: String      // e.g. "1.2 GB of 4.5 GB · 12 MB/s"
        var progress: Double    // 0...1
        var count: Int
        /// A bar between these dates keeps moving on its own while iOS has the app asleep.
        var timerStart: Date?
        var timerEnd: Date?

        var percentText: String {
            switch phase {
            case .finished: return "Done"
            case .failed: return "Failed"
            case .paused: return "Paused"
            default: return "\(Int((min(max(progress, 0), 1) * 100).rounded(.down)))%"
            }
        }
    }
}
