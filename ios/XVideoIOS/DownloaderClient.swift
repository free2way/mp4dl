import Foundation

enum DownloaderError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case api(String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "Server URL is invalid."
        case .invalidResponse:
            return "The server returned an unexpected response."
        case .api(let message):
            return message
        }
    }
}

final class DownloaderClient {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = .shared
        session = URLSession(configuration: configuration)
    }

    func health(server: String) async throws {
        _ = try await request(server: server, path: "/api/health")
    }

    func login(server: String, username: String, password: String) async throws {
        let payload: [String: Any] = [
            "username": username,
            "password": password,
        ]
        _ = try await request(server: server, path: "/api/login", method: "POST", body: payload)
    }

    func system(server: String) async throws -> SystemInfo {
        let json = try await request(server: server, path: "/api/system")
        return SystemInfo(
            ytDlpVersion: json["ytDlpVersion"] as? String ?? "Not installed",
            ffmpegAvailable: json["ffmpeg"] as? Bool ?? false,
            downloadDir: json["downloadDir"] as? String ?? ""
        )
    }

    func parseFormats(server: String, url: String, cookieSource: CookieSource) async throws -> ParsedVideo {
        let json = try await request(
            server: server,
            path: "/api/formats",
            method: "POST",
            body: [
                "url": url,
                "cookieSource": cookieSource.rawValue,
            ]
        )
        let rawFormats = json["formats"] as? [[String: Any]] ?? []
        let formats = rawFormats.compactMap { item -> FormatOption? in
            guard let value = item["value"] as? String ?? item["formatId"] as? String else {
                return nil
            }
            let label = item["label"] as? String
                ?? item["resolution"] as? String
                ?? item["formatNote"] as? String
                ?? value
            let size = int64(from: item["size"] ?? item["filesize"] ?? item["filesizeApprox"])
            return FormatOption(value: value, label: label, size: size)
        }
        return ParsedVideo(
            title: json["title"] as? String ?? "video",
            platform: json["platform"] as? String ?? "Video",
            downloadDir: json["downloadDir"] as? String ?? "",
            formats: formats
        )
    }

    func startDownload(
        server: String,
        url: String,
        cookieSource: CookieSource,
        quality: FormatOption,
        title: String,
        downloadDir: String
    ) async throws -> DownloadJob {
        var payload: [String: Any] = [
            "url": url,
            "cookieSource": cookieSource.rawValue,
            "quality": quality.value,
            "title": title,
            "resolution": quality.label,
            "downloadDir": downloadDir,
            "includeSubtitles": false,
            "subtitleLang": "all",
        ]
        if let size = quality.size {
            payload["expectedSize"] = size
        }
        let json = try await request(
            server: server,
            path: "/api/download",
            method: "POST",
            body: payload
        )
        return try parseJob(json)
    }

    func job(server: String, id: String) async throws -> DownloadJob {
        let json = try await request(server: server, path: "/api/jobs/\(id)")
        return try parseJob(json)
    }

    private func request(
        server: String,
        path: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) async throws -> [String: Any] {
        guard var components = URLComponents(string: server) else {
            throw DownloaderError.invalidServerURL
        }
        components.path = path
        guard let url = components.url else {
            throw DownloaderError.invalidServerURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloaderError.invalidResponse
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let json = object as? [String: Any] else {
            throw DownloaderError.invalidResponse
        }
        if !(200..<300).contains(httpResponse.statusCode) {
            throw DownloaderError.api(json["error"] as? String ?? "Request failed.")
        }
        return json
    }

    private func parseJob(_ json: [String: Any]) throws -> DownloadJob {
        guard let id = json["id"] as? String else {
            throw DownloaderError.invalidResponse
        }
        return DownloadJob(
            id: id,
            status: json["status"] as? String ?? "unknown",
            progress: double(from: json["progress"]) ?? 0,
            message: json["message"] as? String ?? "",
            error: json["error"] as? String,
            outputName: json["outputName"] as? String,
            log: json["log"] as? [String] ?? []
        )
    }
}

private func double(from value: Any?) -> Double? {
    if let value = value as? Double { return value }
    if let value = value as? Int { return Double(value) }
    if let value = value as? String { return Double(value) }
    return nil
}

private func int64(from value: Any?) -> Int64? {
    if let value = value as? Int64 { return value }
    if let value = value as? Int { return Int64(value) }
    if let value = value as? Double { return Int64(value) }
    if let value = value as? String { return Int64(value) }
    return nil
}
