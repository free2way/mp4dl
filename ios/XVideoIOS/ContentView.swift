import SwiftUI

@MainActor
final class DownloaderViewModel: ObservableObject {
    @Published var serverURL = "http://127.0.0.1:8765"
    @Published var username = "admin"
    @Published var password = "admin234"
    @Published var videoURL = ""
    @Published var saveDirectory = ""
    @Published var cookieSource: CookieSource = .none
    @Published var selectedFormat: FormatOption?
    @Published var parsedVideo: ParsedVideo?
    @Published var systemInfo: SystemInfo?
    @Published var currentJob: DownloadJob?
    @Published var status = "Not connected"
    @Published var isBusy = false
    @Published var isAuthenticated = false

    private let client = DownloaderClient()
    private var pollingTask: Task<Void, Never>?

    var canDownload: Bool {
        isAuthenticated && selectedFormat != nil && !videoURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func connect() {
        run("Connecting...") { [self] in
            try await self.client.health(server: self.serverURL)
            try await self.client.login(server: self.serverURL, username: self.username, password: self.password)
            let system = try await self.client.system(server: self.serverURL)
            self.systemInfo = system
            self.saveDirectory = system.downloadDir
            self.isAuthenticated = true
            self.status = "Connected"
        }
    }

    func refreshSystem() {
        run("Refreshing...") { [self] in
            let system = try await self.client.system(server: self.serverURL)
            self.systemInfo = system
            if self.saveDirectory.isEmpty {
                self.saveDirectory = system.downloadDir
            }
            self.status = "System ready"
        }
    }

    func parse() {
        let trimmedURL = videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        run("Parsing formats...") { [self] in
            let parsed = try await self.client.parseFormats(server: self.serverURL, url: trimmedURL, cookieSource: self.cookieSource)
            self.parsedVideo = parsed
            self.selectedFormat = parsed.formats.first
            if self.saveDirectory.isEmpty {
                self.saveDirectory = parsed.downloadDir
            }
            self.status = "\(parsed.formats.count) formats available"
        }
    }

    func download() {
        guard let selectedFormat else { return }
        let trimmedURL = videoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = parsedVideo?.title ?? "video"
        run("Starting download...") { [self] in
            let job = try await self.client.startDownload(
                server: self.serverURL,
                url: trimmedURL,
                cookieSource: self.cookieSource,
                quality: selectedFormat,
                title: title,
                downloadDir: self.saveDirectory
            )
            self.currentJob = job
            self.status = job.statusLabel
            self.startPolling(jobID: job.id)
        }
    }

    func startPolling(jobID: String) {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                do {
                    let job = try await client.job(server: serverURL, id: jobID)
                    currentJob = job
                    status = job.statusLabel
                    if job.isFinished {
                        pollingTask = nil
                        break
                    }
                } catch {
                    status = error.localizedDescription
                    pollingTask = nil
                    break
                }
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    private func run(_ busyStatus: String, operation: @escaping () async throws -> Void) {
        isBusy = true
        status = busyStatus
        Task {
            do {
                try await operation()
            } catch {
                status = error.localizedDescription
            }
            isBusy = false
        }
    }
}

struct ContentView: View {
    @StateObject private var viewModel = DownloaderViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    connectionSection
                    statusSection
                    downloadSection
                    jobSection
                }
                .padding(22)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("X Video")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LOCAL CLIENT")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            Text("Mac mini Downloader")
                .font(.largeTitle.weight(.bold))
            Text("Connect to the local Python service, parse a video link, and save the download on this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Connection")
            TextField("Server", text: $viewModel.serverURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
            HStack {
                TextField("Username", text: $viewModel.username)
                    .textInputAutocapitalization(.never)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $viewModel.password)
                    .textFieldStyle(.roundedBorder)
            }
            Button {
                viewModel.connect()
            } label: {
                Label(viewModel.isAuthenticated ? "Reconnect" : "Connect", systemImage: "bolt.horizontal.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isBusy)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("System")
            HStack {
                metric("yt-dlp", viewModel.systemInfo?.ytDlpVersion ?? "-")
                metric("ffmpeg", viewModel.systemInfo?.ffmpegAvailable == true ? "Ready" : "-")
            }
            Text(viewModel.status)
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
            Picker("Cookies", selection: $viewModel.cookieSource) {
                ForEach(CookieSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }
            .pickerStyle(.segmented)
            TextField("Save directory on Mac mini", text: $viewModel.saveDirectory)
                .textInputAutocapitalization(.never)
                .textFieldStyle(.roundedBorder)
            Button {
                viewModel.parse()
            } label: {
                Label("Parse Formats", systemImage: "list.bullet.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.isAuthenticated || viewModel.isBusy)

            if let parsedVideo = viewModel.parsedVideo {
                VStack(alignment: .leading, spacing: 8) {
                    Text(parsedVideo.title)
                        .font(.headline)
                    Text(parsedVideo.platform)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Quality", selection: $viewModel.selectedFormat) {
                        ForEach(parsedVideo.formats) { format in
                            Text("\(format.label) · \(format.sizeLabel)").tag(Optional(format))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            Button {
                viewModel.download()
            } label: {
                Label("Start Download", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canDownload || viewModel.isBusy)
        }
    }

    @ViewBuilder
    private var jobSection: some View {
        if let job = viewModel.currentJob {
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("Progress")
                ProgressView(value: job.progress, total: 100)
                Text("\(Int(job.progress))% · \(job.statusLabel)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let outputName = job.outputName {
                    Text(outputName)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
                if !job.log.isEmpty {
                    Text(job.log.suffix(4).joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
