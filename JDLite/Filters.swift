import Foundation

/// File type groups, used by the list's filter menu and the file icons.
enum FileKind: String, CaseIterable, Identifiable {
    case archive, video, audio, document, app, diskImage, image, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .archive: return "Archives"
        case .video: return "Videos"
        case .audio: return "Audio"
        case .document: return "Documents"
        case .app: return "Apps & Installers"
        case .diskImage: return "Disk Images"
        case .image: return "Images"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .archive: return "doc.zipper"
        case .video: return "film"
        case .audio: return "music.note"
        case .document: return "doc.richtext"
        case .app: return "app.badge"
        case .diskImage: return "opticaldiscdrive"
        case .image: return "photo"
        case .other: return "doc"
        }
    }

    static func of(_ name: String) -> FileKind {
        let lower = name.lowercased()
        // Split archives: movie.r00, archive.z01, movie.7z.001
        if lower.range(of: #"\.(r\d{2}|z\d{2}|\d{3})$"#, options: .regularExpression) != nil { return .archive }
        switch (lower as NSString).pathExtension {
        case "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "zst", "cab", "lz", "lzma":
            return .archive
        case "mp4", "m4v", "mkv", "mov", "avi", "webm", "wmv", "flv", "ts", "m2ts", "mpg", "mpeg", "3gp":
            return .video
        case "mp3", "m4a", "m4b", "aac", "flac", "wav", "ogg", "opus", "wma", "aiff", "ape", "alac":
            return .audio
        case "pdf", "epub", "mobi", "azw", "azw3", "cbz", "cbr", "djvu", "doc", "docx", "xls", "xlsx",
             "ppt", "pptx", "txt", "rtf", "odt", "srt", "ass", "ssa", "sub":
            return .document
        case "ipa", "tipa", "apk", "xapk", "apks", "deb", "dmg", "pkg", "exe", "msi", "appimage", "rpm", "jar":
            return .app
        case "iso", "img", "bin", "cue", "vhd", "vmdk":
            return .diskImage
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "avif", "bmp", "tiff":
            return .image
        default:
            return .other
        }
    }
}

/// Order of the download list, by when each download was added.
enum SortOrder: String, CaseIterable {
    case newest, oldest
}

/// Which downloads the list shows.
enum StatusFilter: String, CaseIterable {
    case all, downloading, failed, completed

    var title: String {
        switch self {
        case .all: return "All"
        case .downloading: return "Downloading"
        case .failed: return "Failed"
        case .completed: return "Completed"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "tray.full"
        case .downloading: return "arrow.down.circle"
        case .failed: return "exclamationmark.circle"
        case .completed: return "checkmark.circle"
        }
    }

    /// "Downloading" covers everything unfinished: queued, fetching, downloading and paused.
    func matches(_ item: DownloadItem) -> Bool {
        switch self {
        case .all: return true
        case .downloading: return item.state != .completed && item.state != .failed
        case .failed: return item.state == .failed
        case .completed: return item.state == .completed
        }
    }
}
