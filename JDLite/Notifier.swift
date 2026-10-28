import UIKit
import UserNotifications

/// Lets you know when downloads finish or fail while JDLite isn't on screen.
@MainActor
final class Notifier {
    static let shared = Notifier()

    func askPermissionIfNeeded() {
        guard AppSettings.shared.notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func finished(_ item: DownloadItem) {
        post(id: "done-\(item.id.uuidString)", title: "Download finished", body: item.fileName)
    }

    /// A torrent is ready on TorBox and waits for you to pick which files to download.
    func chooseFiles(_ item: DownloadItem) {
        let count = item.choices?.count ?? 0
        post(id: "choose-\(item.id.uuidString)", title: "Choose files to download",
             body: "\(item.fileName) is ready on TorBox (\(count) files). Open JDLite to pick which ones you want.")
    }

    /// Every file of a torrent has finished.
    func torrentFinished(name: String, files: Int, group: UUID) {
        post(id: "done-\(group.uuidString)", title: "Torrent finished", body: "\(name) · \(files) files")
    }

    func failed(_ item: DownloadItem) {
        var body = item.fileName
        if let error = item.error, !error.isEmpty { body += "\n" + error }
        post(id: "failed-\(item.id.uuidString)", title: "Download failed", body: body)
    }

    private func post(id: String, title: String, body: String) {
        // While JDLite is open the list already shows this.
        guard AppSettings.shared.notificationsEnabled,
              UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "downloads"
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
