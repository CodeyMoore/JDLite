import SwiftUI
import UIKit
import UniformTypeIdentifiers
import MachO

// MARK: - Showing the Files picker

/// A request to show the Files picker. Every request is new, so tapping again always opens it again.
struct FilesPickRequest: Identifiable, Equatable {
    let id = UUID()
    var types: [UTType]
    var asCopy = false
    var multiple = false
    /// Record what the picker does in `PickerLog` (shown in Settings).
    var logs = false
}

extension View {
    /// Shows the Files picker whenever `request` is set, and clears it again when the picker closes.
    /// `onFinish` gets the items picked, or nothing if the picker was cancelled.
    func filesPicker(_ request: Binding<FilesPickRequest?>, onFinish: @escaping ([URL]) -> Void) -> some View {
        modifier(FilesPickerModifier(request: request, onFinish: onFinish))
    }
}

/// Shows the picker the standard UIKit way, from the window this view is in. If it doesn't
/// appear, or closes the moment it appears, it's shown inside a SwiftUI sheet instead.
struct FilesPickerModifier: ViewModifier {
    @Binding var request: FilesPickRequest?
    let onFinish: ([URL]) -> Void

    @State private var anchor = ViewAnchor()
    @State private var sheetRequest: FilesPickRequest?

    init(request: Binding<FilesPickRequest?>, onFinish: @escaping ([URL]) -> Void) {
        _request = request
        self.onFinish = onFinish
    }

    func body(content: Content) -> some View {
        content
            .background(AnchorView(anchor: anchor))
            .onChange(of: request) { _, newRequest in
                if let newRequest { present(newRequest) }
            }
            .sheet(item: $sheetRequest) { req in
                DocumentPicker(request: req) { urls in
                    finish(urls, for: req)
                }
                .ignoresSafeArea()
            }
    }

    private func present(_ req: FilesPickRequest) {
        DirectDocumentPicker.present(req, from: anchor.view, onFailure: { reason in
            guard request?.id == req.id else { return }
            if req.logs { PickerLog.shared.add(reason + ", so showing it in a sheet instead") }
            sheetRequest = req
        }, onFinish: { urls in
            finish(urls, for: req)
        })
    }

    private func finish(_ urls: [URL], for req: FilesPickRequest) {
        guard request?.id == req.id else { return }
        request = nil
        if sheetRequest?.id == req.id {
            // The picker closes its own sheet; this makes sure SwiftUI knows it's closed.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                if sheetRequest?.id == req.id { sheetRequest = nil }
            }
        }
        onFinish(urls)
    }
}

/// The system Files picker, reporting when it appears and when it closes.
final class TrackedDocumentPicker: UIDocumentPickerViewController {
    enum Event {
        case appeared(visible: Bool)
        case disappeared
    }

    var onEvent: ((Event) -> Void)?

    /// A new picker each time: reusing one can leave it stuck on a spinner (seen in iOS 26).
    static func make(for request: FilesPickRequest) -> TrackedDocumentPicker {
        let picker = TrackedDocumentPicker(forOpeningContentTypes: request.types, asCopy: request.asCopy)
        picker.allowsMultipleSelection = request.multiple
        return picker
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let window = view.window
        let visible = window != nil && window?.isHidden == false
            && window?.windowScene?.activationState == .foregroundActive
        onEvent?(.appeared(visible: visible))
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onEvent?(.disappeared)
    }
}

/// Gets the picker's answer (once) and records what the picker does.
@MainActor
final class PickerHandler: NSObject, UIDocumentPickerDelegate {
    var onFinish: (([URL]) -> Void)?
    /// Called instead of `onFinish` if the picker closed right after appearing without answering.
    var onClosedAtOnce: (() -> Void)?
    private(set) var appeared = false
    private(set) var finished = false
    private var appearedAt: Date?
    private let logs: Bool

    init(logs: Bool) {
        self.logs = logs
    }

    func attach(to picker: TrackedDocumentPicker) {
        picker.delegate = self
        picker.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    func log(_ text: String) {
        if logs { PickerLog.shared.add(text) }
    }

    /// Stops listening: the caller has given up on this picker.
    func giveUp() {
        finished = true
        onFinish = nil
        onClosedAtOnce = nil
    }

    private func handle(_ event: TrackedDocumentPicker.Event) {
        switch event {
        case .appeared(let visible):
            appeared = true
            appearedAt = Date()
            log(visible ? "Picker is on screen" : "Picker appeared, but not in a window you can see")
        case .disappeared:
            log("Picker closed")
            guard !finished else { return }
            let quick = appearedAt.map { Date().timeIntervalSince($0) < 1 } ?? true
            Task { @MainActor in
                // Its answer can arrive just after it closes.
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !self.finished else { return }
                if quick, let closedAtOnce = self.onClosedAtOnce {
                    self.giveUp()
                    closedAtOnce()
                    return
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !self.finished else { return }
                self.log("It closed without an answer")
                self.finish([])
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        log(urls.isEmpty ? "Answer: nothing picked" : "Answer: " + urls.map { $0.path }.joined(separator: ", "))
        finish(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        log("Answer: cancelled")
        finish([])
    }

    /// Tapping quickly can report a pick twice; only the first answer counts.
    private func finish(_ urls: [URL]) {
        guard !finished else { return }
        let callback = onFinish
        giveUp()   // also lets go of the callbacks
        callback?(urls)
    }
}

/// The Files picker for use inside a SwiftUI sheet (the fallback).
struct DocumentPicker: UIViewControllerRepresentable {
    var request: FilesPickRequest
    var onFinish: ([URL]) -> Void

    func makeCoordinator() -> PickerHandler {
        PickerHandler(logs: request.logs)
    }

    func makeUIViewController(context: Context) -> TrackedDocumentPicker {
        let picker = TrackedDocumentPicker.make(for: request)
        context.coordinator.onFinish = onFinish
        context.coordinator.attach(to: picker)
        context.coordinator.log("Showing the picker in a sheet")
        return picker
    }

    func updateUIViewController(_ picker: TrackedDocumentPicker, context: Context) {
        context.coordinator.onFinish = onFinish
    }
}

/// Shows the Files picker straight from UIKit, on top of whatever is showing in a window.
@MainActor
enum DirectDocumentPicker {
    /// The handler of the picker on screen. The picker's delegate is weak, so this keeps it alive.
    private static var current: PickerHandler?

    /// - Parameters:
    ///   - anchor: a view in the window to show the picker in (the key window if nil).
    ///   - onFailure: called if the picker didn't appear, or closed the moment it appeared.
    ///   - onFinish: called once, with the items picked (nothing if cancelled).
    static func present(_ request: FilesPickRequest, from anchor: UIView?,
                        onFailure: @escaping (String) -> Void,
                        onFinish: @escaping ([URL]) -> Void) {
        var screens: [String] = []
        var top = (anchor?.window ?? keyWindow())?.rootViewController
        while let vc = top {
            screens.append(String(describing: type(of: vc)))
            guard let next = vc.presentedViewController, !next.isBeingDismissed else { break }
            top = next
        }
        guard let presenter = top else {
            if request.logs { PickerLog.shared.add("No window to show the picker in") }
            onFailure("It had nowhere to appear")
            return
        }

        let handler = PickerHandler(logs: request.logs)
        DirectDocumentPicker.current = handler
        handler.onFinish = { urls in
            if DirectDocumentPicker.current === handler { DirectDocumentPicker.current = nil }
            onFinish(urls)
        }
        handler.onClosedAtOnce = {
            if DirectDocumentPicker.current === handler { DirectDocumentPicker.current = nil }
            onFailure("It closed the moment it appeared")
        }
        let picker = TrackedDocumentPicker.make(for: request)
        handler.attach(to: picker)
        handler.log("Showing the picker over " + screens.joined(separator: " › "))
        presenter.present(picker, animated: true)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !handler.appeared, !handler.finished else { return }
            handler.giveUp()
            if DirectDocumentPicker.current === handler { DirectDocumentPicker.current = nil }
            onFailure("It didn't appear")
        }
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        for scene in active + scenes {
            if let window = scene.keyWindow ?? scene.windows.first(where: { !$0.isHidden }) {
                return window
            }
        }
        return nil
    }
}

/// Remembers the UIKit view behind a SwiftUI view, to know which window that view is in.
final class ViewAnchor {
    weak var view: UIView?
}

struct AnchorView: UIViewRepresentable {
    let anchor: ViewAnchor

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        anchor.view = view
    }
}

// MARK: - Diagnostics

/// What the folder picker did last time, shown in Settings so a failed attempt can be tracked down.
@MainActor
final class PickerLog: ObservableObject {
    static let shared = PickerLog()

    @Published private(set) var lines: [String] = []

    private let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.S"
        return formatter
    }()

    func add(_ event: String) {
        lines.append(clock.string(from: Date()) + "  " + event)
        if lines.count > 16 { lines.removeFirst(lines.count - 16) }
    }

    func clear() {
        lines = []
    }
}

/// How this copy of JDLite is installed and signed. Shown in Settings, because some install
/// problems (like the Files picker not handing over folders) come from how an app was signed.
enum AppIdentity {
    /// The bundle ID the app reports, plus the one in its Info.plist file if they differ.
    static let bundleID: String = {
        let reported = Bundle.main.bundleIdentifier ?? "?"
        guard let url = Bundle.main.url(forResource: "Info", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let inFile = plist["CFBundleIdentifier"] as? String else {
            return reported
        }
        return inFile == reported ? reported : "\(reported) (file says \(inFile))"
    }()

    /// The app ID and team in the provisioning profile the app was signed with.
    static let signedAs: String = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url) else {
            return "No profile"
        }
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any] else {
            return "Unreadable profile"
        }
        let entitlements = plist["Entitlements"] as? [String: Any]
        let appID = entitlements?["application-identifier"] as? String ?? "?"
        let team = plist["TeamName"] as? String ?? ""
        return team.isEmpty ? appID : "\(appID) (\(team))"
    }()

    /// Code libraries loaded from inside the app other than JDLite itself, e.g. added by a signing service.
    static let addedLibraries: String = {
        func trimmed(_ path: String) -> String {
            path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
        }
        let appPath = trimmed(Bundle.main.bundlePath) + "/"
        let executable = trimmed(Bundle.main.executablePath ?? "")
        var names: [String] = []
        for index in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(index) else { continue }
            let path = trimmed(String(cString: cName))
            if path.hasPrefix(appPath) && path != executable {
                names.append((path as NSString).lastPathComponent)
            }
        }
        return names.isEmpty ? "None" : names.joined(separator: ", ")
    }()
}
