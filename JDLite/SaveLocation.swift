import Foundation
import Combine

/// Where a finished file is going: JDLite's Downloads folder, or a folder the user picked.
struct SaveTarget: Sendable {
    var folder: URL?          // nil: JDLite's Downloads folder
    var folderName: String?
}

/// A file saved in its final place.
struct SavedFile: Sendable {
    var name: String
    var size: Int64
    var bookmark: Data?       // set for files in a folder the user picked
    var folderName: String?   // nil: JDLite's Downloads folder
}

/// The "Save Files To" setting. A folder picked in the Files picker is remembered as a
/// bookmark, which keeps JDLite allowed to write there after the app restarts.
@MainActor
final class SaveLocation: ObservableObject {
    static let shared = SaveLocation()

    private let defaults = UserDefaults.standard
    @Published var useChosenFolder: Bool {
        didSet { defaults.set(useChosenFolder, forKey: "useChosenFolder") }
    }
    @Published private(set) var folderName: String?
    private var bookmark: Data?

    init() {
        bookmark = defaults.data(forKey: "chosenFolderBookmark")
        folderName = defaults.string(forKey: "chosenFolderName")
        _useChosenFolder = Published(wrappedValue: defaults.bool(forKey: "useChosenFolder"))
    }

    /// Remembers a folder picked in the Files picker.
    func choose(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let data = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        bookmark = data
        folderName = url.lastPathComponent
        defaults.set(data, forKey: "chosenFolderBookmark")
        defaults.set(url.lastPathComponent, forKey: "chosenFolderName")
        useChosenFolder = true
    }

    /// Where the next finished file goes.
    func target() -> SaveTarget {
        guard useChosenFolder, let bookmark else { return SaveTarget() }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else {
            return SaveTarget(folder: nil, folderName: folderName)   // gone: falls back to Downloads
        }
        if stale {
            let scoped = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) {
                self.bookmark = fresh
                defaults.set(fresh, forKey: "chosenFolderBookmark")
            }
            if scoped { url.stopAccessingSecurityScopedResource() }
        }
        return SaveTarget(folder: url, folderName: folderName ?? url.lastPathComponent)
    }

    // MARK: Moving files (runs off the main thread)

    /// Moves a finished file into place under a free name. Files that can't go to the chosen
    /// folder (e.g. a USB drive that was unplugged) go to JDLite's Downloads folder instead.
    nonisolated static func save(_ file: URL, name: String, to target: SaveTarget) throws -> SavedFile {
        if let folder = target.folder, folder.startAccessingSecurityScopedResource() {
            defer { folder.stopAccessingSecurityScopedResource() }
            if let saved = try? saveCoordinated(file, name: name, in: folder, folderName: target.folderName) {
                return saved
            }
        }
        let dest = uniqueURL(for: name, in: DownloadManager.downloadsDir)
        try FileManager.default.moveItem(at: file, to: dest)
        return SavedFile(name: dest.lastPathComponent, size: DownloadManager.fileSize(dest), bookmark: nil, folderName: nil)
    }

    nonisolated private static func saveCoordinated(_ file: URL, name: String, in folder: URL,
                                                    folderName: String?) throws -> SavedFile {
        let dest = uniqueURL(for: name, in: folder)
        var coordinationError: NSError?
        var moveError: Error?
        var finalURL = dest
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: dest, options: .forReplacing,
                                                         error: &coordinationError) { target in
            do {
                try FileManager.default.moveItem(at: file, to: target)
                finalURL = target
            } catch {
                moveError = error
            }
        }
        if let error = (coordinationError as Error?) ?? moveError { throw error }
        let bookmark = try? finalURL.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        return SavedFile(name: finalURL.lastPathComponent, size: DownloadManager.fileSize(finalURL),
                         bookmark: bookmark, folderName: folderName ?? folder.lastPathComponent)
    }

    /// Deletes a file saved in a folder the user picked.
    nonisolated static func deleteSaved(bookmark: Data) {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forDeleting, error: &error) { target in
            _ = try? FileManager.default.removeItem(at: target)
        }
    }

    nonisolated static func uniqueURL(for name: String, in folder: URL) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }
}
