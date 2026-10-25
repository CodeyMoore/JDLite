import UIKit
import UniformTypeIdentifiers

/// Shows the Files app's folder picker. It's presented straight from UIKit, on top of
/// whatever is showing, because SwiftUI's file importer can silently fail to appear when
/// it's opened from a menu or from inside another sheet (like Settings).
@MainActor
final class FolderPicker: NSObject, UIDocumentPickerDelegate {
    static let shared = FolderPicker()

    private var completion: ((URL?) -> Void)?

    /// Calls back with the folder picked, or nil if the picker was cancelled.
    func present(_ completion: @escaping (URL?) -> Void) {
        guard let top = Self.topViewController() else {
            completion(nil)
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        self.completion = completion
        top.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let done = completion
        completion = nil
        done?(urls.first)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        let done = completion
        completion = nil
        done?(nil)
    }

    /// The screen on top: the Settings sheet, when it's open.
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }
}
