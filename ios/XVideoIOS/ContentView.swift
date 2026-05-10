import Foundation
import AppKit
import SwiftUI

enum DownloadChoice: String, CaseIterable, Identifiable {
    case bestMP4
    case video1080
    case video720
    case audioMP3

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bestMP4: "Best MP4"
        case .video1080: "1080p"
        case .video720: "720p"
        case .audioMP3: "Audio MP3"
        }
    }

    var detail: String {
        switch self {
        case .bestMP4:
            "Highest quality video with MP4 merge when possible."
        case .video1080:
            "Best MP4 video up to 1080p."
        case .video720:
            "Best MP4 video up to 720p."
        case .audioMP3:
            "Extract audio and save as MP3."
        }
    }

    var ytDlpArguments: [String] {
        switch self {
        case .bestMP4:
            ["-f", "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best", "--merge-output-format", "mp4"]
        case .video1080:
            ["-f", "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080][ext=mp4]/best[height<=1080]", "--merge-output-format", "mp4"]
        case .video720:
            ["-f", "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/best[height<=720][ext=mp4]/best[height<=720]", "--merge-output-format", "mp4"]
        case .audioMP3:
            ["-x", "--audio-format", "mp3", "--audio-quality", "0"]
        }
    }
}

struct VideoSummary: Equatable {
    let title: String
    let platform: String
    let duration: String?

    var displayText: String {
        [title, platform, duration].compactMap { $0 }.joined(separator: "\n")
    }
}

@MainActor
final class DownloaderViewModel: ObservableObject {
    @Published var videoURL = ""
    @Published var saveDirectory: String
    @Published var selectedChoice: DownloadChoice = .bestMP4
    @Published var summary: VideoSummary?
    @Published var status = "Initializing downloader..."
    @Published var engineText = "Checking bundled tools..."
    @Published var progress = 0.0
    @Published var isBusy = false
    @Published var isDownloading = false
    @Published var logLines: [String] = []

    private let supportedHosts = ["x.com", "twitter.com", "youtube.com", "youtu.be", "bilibili.com", "b23.tv"]
    private var currentProcess: Process?

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        saveDirectory = downloads.appendingPathComponent("X Video").path
        checkEngine()
    }

    var canDownload: Bool {
        !isBusy && normalizedURL(showError: false) != nil
    }

    var ytDlpURL: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("yt-dlp/yt-dlp"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    var ffmpegURL: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ffmpeg/bin/ffmpeg"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        return nil
    }

    func checkEngine() {
        Task {
            do {
                guard let ytDlpURL else {
                    throw DownloadError.message("Bundled yt-dlp was not found.")
                }
                guard let ffmpegURL else {
                    throw DownloadError.message("Bundled ffmpeg was not found.")
                }
                let ytDlpVersion = try await runAndCollect(executable: ytDlpURL, arguments: ["--version"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                _ = try await runAndCollect(executable: ffmpegURL, arguments: ["-version"])
                engineText = "yt-dlp \(ytDlpVersion) / ffmpeg ready"
                status = "Ready"
            } catch {
                engineText = cleanMessage(error)
                status = "Downloader engine is not ready"
            }
        }
    }

    func pasteLink() {
        if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            videoURL = text
            status = "Link pasted"
        } else {
            status = "Clipboard is empty"
        }
    }

    func checkVideo() {
        guard let url = normalizedURL(showError: true), let ytDlpURL else { return }
        run("Checking video...") {
            let output = try await self.runAndCollect(
                executable: ytDlpURL,
                arguments: ["--no-playlist", "--dump-json", url]
            )
            self.summary = try self.parseSummary(output)
            self.status = self.summary?.displayText ?? "Video is available"
        }
    }

    func toggleDownload() {
        if isDownloading {
            currentProcess?.terminate()
            status = "Canceling download..."
            return
        }
        startDownload()
    }

    func openSaveFolder() {
        ensureDownloadDirectory()
        NSWorkspace.shared.open(URL(fileURLWithPath: saveDirectory))
    }

    private func startDownload() {
        guard let url = normalizedURL(showError: true), let ytDlpURL else { return }
        guard let ffmpegURL else {
            status = "Bundled ffmpeg was not found."
            return
        }

        ensureDownloadDirectory()
        progress = 0
        logLines.removeAll()
        isBusy = true
        isDownloading = true
        status = "Starting download..."

        var arguments = [
            "--no-playlist",
            "--newline",
            "--no-mtime",
            "--ffmpeg-location", ffmpegURL.deletingLastPathComponent().path,
            "-P", saveDirectory,
            "-o", "%(title).180s [%(id)s].%(ext)s",
        ]
        arguments.append(contentsOf: selectedChoice.ytDlpArguments)
        arguments.append(url)

        Task {
            do {
                try await runStreaming(executable: ytDlpURL, arguments: arguments)
                progress = 100
                status = "Saved to \(saveDirectory)"
            } catch {
                status = cleanMessage(error)
            }
            isBusy = false
            isDownloading = false
            currentProcess = nil
        }
    }

    private func run(_ busyStatus: String, operation: @escaping () async throws -> Void) {
        isBusy = true
        status = busyStatus
        Task {
            do {
                try await operation()
            } catch {
                status = cleanMessage(error)
            }
            isBusy = false
        }
    }

    private func normalizedURL(showError: Bool) -> String? {
        let trimmed = videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased().removingWWWPrefix(),
              supportedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        else {
            if showError {
                status = "Use an X, YouTube, or Bilibili link"
            }
            return nil
        }
        return trimmed
    }

    private func ensureDownloadDirectory() {
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: saveDirectory),
            withIntermediateDirectories: true
        )
    }

    private func runAndCollect(executable: URL, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = childEnvironment()

            var output = Data()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                output.append(handle.availableData)
            }

            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                output.append(pipe.fileHandleForReading.readDataToEndOfFile())
                let text = String(data: output, encoding: .utf8) ?? ""
                if finished.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: DownloadError.message(text.firstNonEmptyLine ?? "Command failed"))
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func runStreaming(executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = childEnvironment()
            currentProcess = process

            var buffer = Data()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                buffer.append(data)
                while let newlineRange = buffer.firstRange(of: Data([0x0A])) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                    buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)
                    guard let line = String(data: lineData, encoding: .utf8) else { continue }
                    Task { @MainActor in
                        self?.consumeDownloadLine(line)
                    }
                }
            }

            process.terminationHandler = { [weak self] finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    Task { @MainActor in
                        if self?.isDownloading == false {
                            continuation.resume(throwing: DownloadError.message("Download canceled"))
                        } else {
                            continuation.resume(throwing: DownloadError.message("Download failed"))
                        }
                    }
                }
            }

            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func consumeDownloadLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        logLines.append(line)
        logLines = Array(logLines.suffix(8))
        status = line

        if let percent = line.downloadPercent {
            progress = percent
        }
    }

    private func parseSummary(_ output: String) throws -> VideoSummary {
        guard let jsonLine = output.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
              let data = String(jsonLine).data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw DownloadError.message("Could not parse video information.")
        }
        let title = object["title"] as? String ?? "Untitled video"
        let platform = object["extractor_key"] as? String ?? "Video"
        let duration = (object["duration"] as? Double).map { Self.formatDuration(Int($0)) }
        return VideoSummary(title: title, platform: platform, duration: duration)
    }

    private func childEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let ffmpegURL {
            let binPath = ffmpegURL.deletingLastPathComponent().path
            environment["PATH"] = "\(binPath):/usr/bin:/bin:/usr/sbin:/sbin"
        }
        environment["PYTHONIOENCODING"] = "utf-8"
        return environment
    }

    private func cleanMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message.firstNonEmptyLine ?? message
        }
        return error.localizedDescription.firstNonEmptyLine ?? "Unknown error"
    }

    private static func formatDuration(_ seconds: Int) -> String {
        let safe = max(0, seconds)
        let hours = safe / 3600
        let minutes = safe % 3600 / 60
        let remaining = safe % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%d:%02d", minutes, remaining)
    }
}

struct ContentView: View {
    @StateObject private var viewModel = DownloaderViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    engineSection
                    downloadSection
                    progressSection
                }
                .padding(22)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("X Video")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MAC DOWNLOADER")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text("X Video")
                .font(.largeTitle.weight(.bold))
            Text("Paste a public video link and save it on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Engine")
            Text(viewModel.engineText)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !viewModel.saveDirectory.isEmpty {
                Text(viewModel.saveDirectory)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var downloadSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Download")
            TextEditor(text: $viewModel.videoURL)
                .frame(minHeight: 82)
                .padding(8)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18))
                )

            Button {
                viewModel.pasteLink()
            } label: {
                Label("Paste Link", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isBusy)

            Picker("Quality", selection: $viewModel.selectedChoice) {
                ForEach(DownloadChoice.allCases) { choice in
                    Text(choice.label).tag(choice)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isDownloading)

            Text(viewModel.selectedChoice.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)

            TextField("Save folder", text: $viewModel.saveDirectory)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .disabled(viewModel.isDownloading)

            HStack {
                Button {
                    viewModel.checkVideo()
                } label: {
                    Label("Check Video", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isBusy)

                Button {
                    viewModel.openSaveFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                viewModel.toggleDownload()
            } label: {
                Label(
                    viewModel.isDownloading ? "Cancel" : "Download",
                    systemImage: viewModel.isDownloading ? "xmark.circle.fill" : "arrow.down.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canDownload && !viewModel.isDownloading)
        }
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Status")
            ProgressView(value: viewModel.progress, total: 100)
            Text(viewModel.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let summary = viewModel.summary {
                Text(summary.displayText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.top, 4)
            }

            if !viewModel.logLines.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.logLines, id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.headline)
    }
}

private enum DownloadError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

private extension String {
    func removingWWWPrefix() -> String {
        if hasPrefix("www.") {
            return String(dropFirst(4))
        }
        if hasPrefix("m.") {
            return String(dropFirst(2))
        }
        return self
    }

    var firstNonEmptyLine: String? {
        split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }?
            .prefix(240)
            .description
    }

    var downloadPercent: Double? {
        guard let range = range(of: #"\[download\]\s+([0-9]+(?:\.[0-9]+)?)%"#, options: .regularExpression) else {
            return nil
        }
        let fragment = String(self[range])
        guard let percentRange = fragment.range(of: #"[0-9]+(?:\.[0-9]+)?"#, options: .regularExpression),
              let value = Double(fragment[percentRange])
        else {
            return nil
        }
        return min(100, max(0, value))
    }
}
