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

enum DownloadQueueStatus: String {
    case queued
    case running
    case completed
    case failed
    case canceled

    var label: String {
        switch self {
        case .queued: "Queued"
        case .running: "Downloading"
        case .completed: "Done"
        case .failed: "Failed"
        case .canceled: "Canceled"
        }
    }
}

struct DownloadQueueItem: Identifiable, Equatable {
    let id: UUID
    let url: String
    var status: DownloadQueueStatus = .queued
    var progress: Double = 0
    var message: String = "Waiting"
    var logLines: [String] = []

    var displayTitle: String {
        URLComponents(string: url)?.host ?? url
    }
}

@MainActor
final class DownloaderViewModel: ObservableObject {
    @Published var videoURL = ""
    @Published var saveDirectory: String
    @Published var selectedChoice: DownloadChoice = .bestMP4
    @Published var concurrency = 3
    @Published var jobs: [DownloadQueueItem] = []
    @Published var status = "Initializing downloader..."
    @Published var engineText = "Checking bundled tools..."
    @Published var progress = 0.0
    @Published var isBusy = false
    @Published var isDownloading = false

    private let supportedHosts = ["x.com", "twitter.com", "youtube.com", "youtu.be", "bilibili.com", "b23.tv"]
    private var currentProcesses: [UUID: Process] = [:]

    init() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        saveDirectory = downloads.appendingPathComponent("X Video").path
        checkEngine()
    }

    var canDownload: Bool {
        !isBusy && !validLinks(showError: false).isEmpty
    }

    var completedCount: Int {
        jobs.filter { $0.status == .completed }.count
    }

    var runningCount: Int {
        jobs.filter { $0.status == .running }.count
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

    func pasteLinks() {
        if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            videoURL = text
            prepareQueue()
            status = "\(jobs.count) link\(jobs.count == 1 ? "" : "s") ready"
        } else {
            status = "Clipboard is empty"
        }
    }

    func prepareQueue() {
        let links = validLinks(showError: true)
        jobs = links.map {
            DownloadQueueItem(id: UUID(), url: $0)
        }
        progress = 0
        if links.isEmpty {
            status = "Paste one or more X, YouTube, or Bilibili links"
        } else {
            status = "\(links.count) link\(links.count == 1 ? "" : "s") ready"
        }
    }

    func toggleDownloads() {
        if isDownloading {
            cancelDownloads()
            return
        }
        startDownloads()
    }

    func openSaveFolder() {
        ensureDownloadDirectory()
        NSWorkspace.shared.open(URL(fileURLWithPath: saveDirectory))
    }

    private func startDownloads() {
        guard ytDlpURL != nil else {
            status = "Bundled yt-dlp was not found."
            return
        }
        guard ffmpegURL != nil else {
            status = "Bundled ffmpeg was not found."
            return
        }

        let links = validLinks(showError: true)
        guard !links.isEmpty else { return }

        ensureDownloadDirectory()
        concurrency = min(5, max(1, concurrency))
        jobs = links.map {
            DownloadQueueItem(id: UUID(), url: $0)
        }
        progress = 0
        isBusy = true
        isDownloading = true
        status = "Starting \(jobs.count) download\(jobs.count == 1 ? "" : "s")..."
        launchQueuedDownloads()
    }

    private func cancelDownloads() {
        isDownloading = false
        status = "Canceling downloads..."
        currentProcesses.values.forEach { $0.terminate() }
        currentProcesses.removeAll()
        for index in jobs.indices {
            if jobs[index].status == .queued || jobs[index].status == .running {
                jobs[index].status = .canceled
                jobs[index].message = "Canceled"
            }
        }
        isBusy = false
        updateOverallProgress()
    }

    private func launchQueuedDownloads() {
        guard isDownloading else { return }

        while runningCount < concurrency,
              let index = jobs.firstIndex(where: { $0.status == .queued }) {
            let job = jobs[index]
            jobs[index].status = .running
            jobs[index].message = "Starting..."
            Task {
                await performDownload(jobID: job.id, url: job.url)
            }
        }

        if currentProcesses.isEmpty && jobs.allSatisfy({ $0.status != .queued && $0.status != .running }) {
            isBusy = false
            isDownloading = false
            let failed = jobs.filter { $0.status == .failed }.count
            let canceled = jobs.filter { $0.status == .canceled }.count
            if failed > 0 || canceled > 0 {
                status = "Finished: \(completedCount) done, \(failed) failed, \(canceled) canceled"
            } else {
                status = "All downloads completed"
            }
            updateOverallProgress()
        }
    }

    private func performDownload(jobID: UUID, url: String) async {
        guard let ytDlpURL, let ffmpegURL else { return }

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

        do {
            try await runStreaming(jobID: jobID, executable: ytDlpURL, arguments: arguments)
            finish(jobID: jobID, status: .completed, progress: 100, message: "Saved")
        } catch {
            let wasCanceled = !isDownloading || (error as? DownloadError)?.errorDescription == "Download canceled"
            finish(
                jobID: jobID,
                status: wasCanceled ? .canceled : .failed,
                progress: job(jobID)?.progress ?? 0,
                message: wasCanceled ? "Canceled" : cleanMessage(error)
            )
        }

        currentProcesses[jobID] = nil
        updateOverallProgress()
        launchQueuedDownloads()
    }

    private func finish(jobID: UUID, status: DownloadQueueStatus, progress: Double, message: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].status = status
        jobs[index].progress = progress
        jobs[index].message = message
    }

    private func job(_ id: UUID) -> DownloadQueueItem? {
        jobs.first { $0.id == id }
    }

    private func validLinks(showError: Bool) -> [String] {
        let candidates = extractCandidateLinks(from: videoURL)
        var seen = Set<String>()
        let links = candidates.compactMap { normalizedURL($0) }.filter { seen.insert($0).inserted }
        if showError && links.isEmpty {
            status = "Use X, YouTube, or Bilibili links, one per line"
        }
        return links
    }

    private func extractCandidateLinks(from text: String) -> [String] {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let detected = detector.matches(in: text, range: fullRange).compactMap { result -> String? in
                guard let range = Range(result.range, in: text) else { return nil }
                return String(text[range]).cleanedURLCandidate
            }
            if !detected.isEmpty {
                return detected
            }
        }

        return text
            .components(separatedBy: .whitespacesAndNewlines)
            .map(\.cleanedURLCandidate)
            .filter { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }
    }

    private func normalizedURL(_ raw: String) -> String? {
        let trimmed = raw.cleanedURLCandidate
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased().removingWWWPrefix(),
              supportedHosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        else {
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

    private func runStreaming(jobID: UUID, executable: URL, arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.environment = childEnvironment()

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
                        self?.consumeDownloadLine(jobID: jobID, line)
                    }
                }
            }

            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else if finished.terminationStatus == 15 {
                    continuation.resume(throwing: DownloadError.message("Download canceled"))
                } else {
                    continuation.resume(throwing: DownloadError.message("Download failed"))
                }
            }

            do {
                try process.run()
                currentProcesses[jobID] = process
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }

    private func consumeDownloadLine(jobID: UUID, _ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        jobs[index].logLines.append(line)
        jobs[index].logLines = Array(jobs[index].logLines.suffix(3))
        jobs[index].message = line

        if let percent = line.downloadPercent {
            jobs[index].progress = percent
            updateOverallProgress()
        }

        let running = runningCount
        status = "\(completedCount)/\(jobs.count) done, \(running) running"
    }

    private func updateOverallProgress() {
        guard !jobs.isEmpty else {
            progress = 0
            return
        }
        let total = jobs.reduce(0.0) { $0 + $1.progress }
        progress = total / Double(jobs.count)
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
                    queueSection
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
            Text("Paste public video links and save them on this Mac.")
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
                .frame(minHeight: 120)
                .padding(8)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.18))
                )
                .disabled(viewModel.isDownloading)

            Button {
                viewModel.pasteLinks()
            } label: {
                Label("Paste Links", systemImage: "doc.on.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isDownloading)

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

            Stepper(value: $viewModel.concurrency, in: 1...5) {
                Text("Concurrent downloads: \(viewModel.concurrency)")
            }
            .disabled(viewModel.isDownloading)

            TextField("Save folder", text: $viewModel.saveDirectory)
                .textFieldStyle(RoundedBorderTextFieldStyle())
                .disabled(viewModel.isDownloading)

            HStack {
                Button {
                    viewModel.prepareQueue()
                } label: {
                    Label("Check Links", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isDownloading)

                Button {
                    viewModel.openSaveFolder()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button {
                viewModel.toggleDownloads()
            } label: {
                Label(
                    viewModel.isDownloading ? "Cancel All" : "Download Queue",
                    systemImage: viewModel.isDownloading ? "xmark.circle.fill" : "arrow.down.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canDownload && !viewModel.isDownloading)
        }
    }

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Queue")
            ProgressView(value: viewModel.progress, total: 100)
            Text(viewModel.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if viewModel.jobs.isEmpty {
                Text("Paste one or more links. Each line can contain one URL.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(viewModel.jobs) { job in
                        queueRow(job)
                    }
                }
            }
        }
    }

    private func queueRow(_ job: DownloadQueueItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(job.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(job.status.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor(job.status))
            }
            ProgressView(value: job.progress, total: 100)
            Text(job.url)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
            Text(job.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            ForEach(job.logLines, id: \.self) { line in
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.secondary.opacity(0.12))
        )
    }

    private func statusColor(_ status: DownloadQueueStatus) -> Color {
        switch status {
        case .queued: .secondary
        case .running: .blue
        case .completed: .green
        case .failed: .red
        case .canceled: .orange
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

    var cleanedURLCandidate: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,;)]}>\"'"))
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
