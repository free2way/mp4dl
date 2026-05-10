import Foundation

struct SystemInfo: Equatable {
    var ytDlpVersion: String
    var ffmpegAvailable: Bool
    var downloadDir: String
}

struct FormatOption: Identifiable, Hashable {
    var id: String { value }
    let value: String
    let label: String
    let size: Int64?

    var sizeLabel: String {
        guard let size, size > 0 else { return "Size unknown" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

struct ParsedVideo: Equatable {
    let title: String
    let platform: String
    let downloadDir: String
    let formats: [FormatOption]
}

struct DownloadJob: Equatable {
    let id: String
    let status: String
    let progress: Double
    let message: String
    let error: String?
    let outputName: String?
    let log: [String]

    var isFinished: Bool {
        status == "completed" || status == "failed"
    }

    var statusLabel: String {
        if let error, !error.isEmpty {
            return error
        }
        if !message.isEmpty {
            return message
        }
        return status.capitalized
    }
}

enum CookieSource: String, CaseIterable, Identifiable {
    case none
    case safari
    case chrome
    case firefox
    case edge
    case brave

    var id: String { rawValue }

    var label: String {
        rawValue.capitalized
    }
}
