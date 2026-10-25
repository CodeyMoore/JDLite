import Foundation

/// One speed limit shared by every in-app connection (a token bucket). Connections that get
/// ahead of the limit pause reading for a moment, which makes the server slow down too.
final class SpeedLimiter: @unchecked Sendable {
    static let shared = SpeedLimiter()

    private let lock = NSLock()
    private var rate: Double = 0          // bytes per second; 0 = no limit
    private var allowance: Double = 0     // bytes that may arrive right now
    private var last = ProcessInfo.processInfo.systemUptime

    /// Sets the limit for all downloads together (0 = no limit).
    func setLimit(bytesPerSecond: Double) {
        lock.lock()
        defer { lock.unlock() }
        rate = max(0, bytesPerSecond)
        allowance = 0
        last = ProcessInfo.processInfo.systemUptime
    }

    var isLimited: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rate > 0
    }

    /// Counts bytes that just arrived. Returns how long to pause before reading more (0 = carry on).
    func take(_ bytes: Int) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard rate > 0 else { return 0 }
        let now = ProcessInfo.processInfo.systemUptime
        // Unused allowance builds up for at most a quarter of a second, so bursts stay short.
        allowance = min(allowance + (now - last) * rate, rate * 0.25)
        last = now
        allowance -= Double(bytes)
        return allowance >= 0 ? 0 : min(-allowance / rate, 5)
    }
}
