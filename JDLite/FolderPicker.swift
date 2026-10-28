import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The Files picker, used to add .torrent files.

/// A request to show the Files picker. Every request is new, so tapping again always opens it again.
struct FilesPickRequest: Identifiable, Equatable {
    let id = UUID()
    var types: [UTType]
    var asCopy = false
    var multiple = false
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
        DirectDocumentPicker.present(req, from: anchor.view, onFailure: {
            guard request?.id == req.id else { return }
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
    enum Event { case appeared, disappeared }

    var onEvent: ((Event) -> Void)?

    /// A new picker each time: reusing one can leave it stuck on a spinner (seen in iOS 26).
    static func make(for request: FilesPickRequest) -> TrackedDocumentPicker {
        let picker = TrackedDocumentPicker(forOpeningContentTypes: request.types, asCopy: request.asCopy)
        picker.allowsMultipleSelection = request.multiple
        return picker
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onEvent?(.appeared)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onEvent?(.disappeared)
    }
}

/// Gets the picker's answer, once.
@MainActor
final class PickerHandler: NSObject, UIDocumentPickerDelegate {
    var onFinish: (([URL]) -> Void)?
    /// Called instead of `onFinish` if the picker closed right after appearing without answering.
    var onClosedAtOnce: (() -> Void)?
    private(set) var appeared = false
    private(set) var finished = false
    private var appearedAt: Date?

    func attach(to picker: TrackedDocumentPicker) {
        picker.delegate = self
        picker.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    /// Stops listening: the caller has given up on this picker.
    func giveUp() {
        finished = true
        onFinish = nil
        onClosedAtOnce = nil
    }

    private func handle(_ event: TrackedDocumentPicker.Event) {
        switch event {
        case .appeared:
            appeared = true
            appearedAt = Date()
        case .disappeared:
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
                self.finish([])
            }
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
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
        PickerHandler()
    }

    func makeUIViewController(context: Context) -> TrackedDocumentPicker {
        let picker = TrackedDocumentPicker.make(for: request)
        context.coordinator.onFinish = onFinish
        context.coordinator.attach(to: picker)
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
                        onFailure: @escaping () -> Void,
                        onFinish: @escaping ([URL]) -> Void) {
        var top = (anchor?.window ?? keyWindow())?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        guard let presenter = top else {
            onFailure()
            return
        }

        let handler = PickerHandler()
        DirectDocumentPicker.current = handler
        handler.onFinish = { urls in
            if DirectDocumentPicker.current === handler { DirectDocumentPicker.current = nil }
            onFinish(urls)
        }
        handler.onClosedAtOnce = {
            if DirectDocumentPicker.current === handler { DirectDocumentPicker.current = nil }
            onFailure()
        }
        let picker = TrackedDocumentPicker.make(for: request)
        handler.attach(to: picker)
        presenter.present(picker, animated: true)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !handler.appeared, !handler.finished else { return }
            handler.giveUp()
            if DirectDocumentPicker.current === handler { DirectDocumentPicker.current = nil }
            onFailure()
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
