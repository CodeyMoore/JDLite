import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Files picker, for use inside a SwiftUI `.sheet`.
///
/// SwiftUI's `.fileImporter`, and presenting the picker from UIKit on top of a SwiftUI sheet,
/// can both fail to show anything on iPhone. The picker shown inside a sheet that SwiftUI
/// presents itself works. A new picker is made each time the sheet opens, because reusing one
/// can leave it stuck on a spinner (seen in iOS 26).
struct DocumentPicker: UIViewControllerRepresentable {
    var types: [UTType]
    var asCopy = false
    var multiple = false
    /// Called once: with the items picked, or with nothing if the picker was cancelled.
    var onFinish: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = multiple
        picker.delegate = context.coordinator
        context.coordinator.onFinish = onFinish
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onFinish: (([URL]) -> Void)?
        private var finished = false

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            finish([])
        }

        /// Tapping quickly can report a pick twice; only the first one counts.
        private func finish(_ urls: [URL]) {
            guard !finished else { return }
            finished = true
            onFinish?(urls)
        }
    }
}

/// Shows the Files picker straight from UIKit, on top of whatever is on screen. Used only if
/// the SwiftUI sheet doesn't appear; if this doesn't work either, it reports what was on
/// screen, so the problem can be tracked down.
@MainActor
final class DirectDocumentPicker: NSObject, UIDocumentPickerDelegate {
    /// The picker on screen. Its delegate is weak, so this keeps it alive until it's done.
    private static var current: DirectDocumentPicker?

    private let onFinish: ([URL]) -> Void
    private var shown = false
    private var finished = false

    private init(onFinish: @escaping ([URL]) -> Void) {
        self.onFinish = onFinish
    }

    /// - Parameters:
    ///   - anchor: a view in the window to show the picker in (the key window if nil).
    ///   - onFailure: called if the picker didn't appear, with the screens that were showing.
    ///   - onFinish: called once, with the items picked (nothing if cancelled).
    static func present(types: [UTType], asCopy: Bool = false, multiple: Bool = false,
                        from anchor: UIView?,
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
            onFailure("no window")
            return
        }
        let handler = DirectDocumentPicker(onFinish: onFinish)
        DirectDocumentPicker.current = handler
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: asCopy)
        picker.allowsMultipleSelection = multiple
        picker.delegate = handler
        presenter.present(picker, animated: true) {
            MainActor.assumeIsolated { handler.shown = true }
        }
        let onScreen = screens.joined(separator: " › ")
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !handler.shown, !handler.finished else { return }
            handler.finished = true
            if DirectDocumentPicker.current === handler { DirectDocumentPicker.current = nil }
            onFailure(onScreen)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish([])
    }

    private func finish(_ urls: [URL]) {
        guard !finished else { return }
        finished = true
        if DirectDocumentPicker.current === self { DirectDocumentPicker.current = nil }
        onFinish(urls)
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
