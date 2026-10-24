import AVFoundation

/// Keeps JDLite running after you leave it while it's downloading, so its in-app connections
/// carry on at full speed instead of handing over to iOS's slower background downloader.
/// It stays awake the way music apps do: by playing silence, mixed with any other audio so
/// nothing else is interrupted. It stops as soon as there's nothing left to download.
@MainActor
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()

    private var player: AVAudioPlayer?
    private var observer: NSObjectProtocol?
    private(set) var isRunning = false

    private init() {
        observer = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
                                                          object: nil, queue: .main) { note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                BackgroundKeeper.shared.interrupted(began: raw == AVAudioSession.InterruptionType.began.rawValue)
            }
        }
    }

    /// Starts playing silence. Returns false if iOS won't allow it.
    @discardableResult
    func start() -> Bool {
        if isRunning { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.mixWithOthers])
            try session.setActive(true)
            let newPlayer = try AVAudioPlayer(data: Self.silence)
            newPlayer.numberOfLoops = -1
            guard newPlayer.play() else { return false }
            player = newPlayer
            isRunning = true
            return true
        } catch {
            return false
        }
    }

    func stop() {
        guard let current = player else {
            isRunning = false
            return
        }
        current.stop()
        player = nil
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// A phone call or another app took over the audio: JDLite can't stay awake any more.
    private func interrupted(began: Bool) {
        guard player != nil else { return }
        stop()
        if began { DownloadManager.shared.keeperInterrupted() }
    }

    /// One second of silent 8 kHz, 16-bit mono audio, as a WAV file.
    private static let silence: Data = {
        let sampleRate: UInt32 = 8000
        let dataSize = sampleRate * 2
        var wav = Data()
        func text(_ s: String) { wav.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { wav.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + dataSize); text("WAVE")
        text("fmt "); u32(16); u16(1); u16(1); u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        text("data"); u32(dataSize)
        wav.append(Data(count: Int(dataSize)))
        return wav
    }()
}
