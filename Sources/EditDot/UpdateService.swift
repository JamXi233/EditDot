// SPDX-License-Identifier: GPL-3.0-only
// Copyright © 2017–2026 JamXi, JSG-LLC.
import Foundation

enum UpdateMode: String, Codable { case normal, forced }

enum UpdateChannel: String, CaseIterable {
    case automatic, jsg, github
    var title: String {
        switch self {
        case .automatic: return tr("updates.automatic_channel")
        case .jsg: return "JSG-LLC"
        case .github: return "GitHub"
        }
    }
    var endpoint: URL {
        URL(string: self == .jsg ? "https://api.jamsg.cn/release/getversion?package=cn.jamsg.editdot" : "https://api.github.com/repos/JamXi233/EditDot/releases/latest")!
    }
}

struct ReleaseVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ value: String) {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
              pieces.allSatisfy({ Int($0) != nil }) else { return nil }
        var numbers = pieces.map { Int($0)! }
        while numbers.count > 1 && numbers.last == 0 { numbers.removeLast() }
        parts = numbers
    }
    static func < (lhs: Self, rhs: Self) -> Bool {
        for i in 0..<max(lhs.parts.count, rhs.parts.count) {
            let a = i < lhs.parts.count ? lhs.parts[i] : 0, b = i < rhs.parts.count ? rhs.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

struct UpdateRelease {
    let version: String
    let channel: UpdateChannel
    let notes: String
    let downloadURL: URL?
    let pageURL: URL?
    let sha256: String?
    func isNewer(than version: String) -> Bool {
        guard let current = ReleaseVersion(version), let latest = ReleaseVersion(self.version) else { return false }
        return latest > current
    }
}

enum UpdateError: LocalizedError {
    case invalidResponse, unavailable, noRelease, rateLimited, noDownload, invalidPackage, checksum, notWritable, cancelled, helper, incompatible, operationFailed
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return tr("updates.invalid_response")
        case .unavailable: return tr("updates.unavailable")
        case .noRelease: return tr("updates.no_release")
        case .rateLimited: return tr("updates.rate_limited")
        case .noDownload: return tr("updates.no_download")
        case .invalidPackage: return tr("updates.invalid_package")
        case .checksum: return tr("updates.checksum_failed")
        case .notWritable: return tr("updates.not_writable")
        case .cancelled: return tr("updates.cancelled")
        case .helper: return tr("updates.install_failed")
        case .incompatible: return tr("updates.incompatible")
        case .operationFailed: return tr("updates.failed")
        }
    }
}

enum ReleaseParser {
    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }
    static func supportsArchitecture(_ filename: String) -> Bool {
        let name = filename.lowercased()
        if name.contains("universal") { return true }
        let intel = ["x86_64", "x64", "intel", "amd64"].contains { name.contains($0) }
        let arm = name.contains("arm64") || name.contains("aarch64")
        return architecture == "arm64" ? !intel : !arm
    }
    static func secureURL(_ value: Any?) -> URL? {
        guard let string = value as? String, let url = URL(string: string), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func digest(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let text = value.lowercased().replacingOccurrences(of: "sha256:", with: "")
        return text.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } ? text : nil
    }
    static func parse(_ data: Data, channel: UpdateChannel, mode: UpdateMode = .normal) throws -> UpdateRelease {
        guard data.count <= 1024 * 1024, let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UpdateError.invalidResponse }
        let json = raw["data"] as? [String: Any] ?? raw
        if channel == .jsg {
            guard json["package"] as? String == "cn.jamsg.editdot", let version = json["version"] as? String, ReleaseVersion(version) != nil else { throw UpdateError.invalidResponse }
            let suppliedHash = json["sha256"] as? String
            if let suppliedHash = suppliedHash, !suppliedHash.isEmpty, digest(suppliedHash) == nil, mode == .normal { throw UpdateError.invalidResponse }
            let download = secureURL(json["link"])
            return UpdateRelease(version: version, channel: .jsg, notes: String((json["changelog"] as? String ?? "").prefix(20000)),
                                 downloadURL: download.flatMap { supportsArchitecture($0.lastPathComponent) ? $0 : nil },
                                 pageURL: secureURL(json["site"]), sha256: digest(suppliedHash))
        }
        guard channel == .github, json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let version = json["tag_name"] as? String, ReleaseVersion(version) != nil else { throw UpdateError.invalidResponse }
        let assets = (json["assets"] as? [[String: Any]] ?? []).filter { asset in
            guard let name = (asset["name"] as? String)?.lowercased(), name.hasPrefix("editdot"), name.hasSuffix(".dmg"),
                  !name.contains("source"), secureURL(asset["browser_download_url"]) != nil else { return false }
            return supportsArchitecture(name)
        }.sorted { a, b in
            func rank(_ asset: [String: Any]) -> Int { ((asset["name"] as? String)?.lowercased().contains(architecture) == true) ? 0 : 1 }
            return rank(a) < rank(b)
        }
        let asset = assets.first
        if let hash = asset?["digest"] as? String, !hash.isEmpty, digest(hash) == nil, mode == .normal { throw UpdateError.invalidResponse }
        return UpdateRelease(version: version, channel: .github, notes: String((json["body"] as? String ?? "").prefix(20000)),
                             downloadURL: secureURL(asset?["browser_download_url"]), pageURL: secureURL(json["html_url"]), sha256: digest(asset?["digest"]))
    }
}

final class UpdateCheck {
    typealias Fetch = (UpdateChannel, @escaping (Result<UpdateRelease, Error>) -> Void) -> (() -> Void)
    private var cancellations: [() -> Void] = []
    private var pending = 0
    private var finished = false
    private var candidate: UpdateRelease?
    private var failure: Error = UpdateError.unavailable
    private let currentVersion: String
    private let mode: UpdateMode
    private let completion: (Result<UpdateRelease, Error>) -> Void
    init(channel: UpdateChannel, currentVersion: String, mode: UpdateMode = .normal, fetch: Fetch, completion: @escaping (Result<UpdateRelease, Error>) -> Void) {
        self.currentVersion = currentVersion; self.mode = mode; self.completion = completion
        let channels: [UpdateChannel] = channel == .automatic ? [.jsg, .github] : [channel]
        pending = channels.count
        for channel in channels {
            cancellations.append(fetch(channel) { [weak self] result in
                DispatchQueue.main.async { self?.received(result) }
            })
        }
    }
    private func received(_ result: Result<UpdateRelease, Error>) {
        guard !finished else { return }
        pending -= 1
        switch result {
        case .success(let release):
            // A newer release without a package lets the other channel finish first.
            if (release.isNewer(than: currentVersion) || mode == .forced) && release.downloadURL == nil {
                if candidate == nil { candidate = release }
            } else { finish(.success(release)); return }
        case .failure(let error): failure = error
        }
        if pending == 0 { finish(candidate.map { .success($0) } ?? .failure(failure)) }
    }
    private func finish(_ result: Result<UpdateRelease, Error>) {
        guard !finished else { return }; finished = true
        cancellations.forEach { $0() }; cancellations = []; completion(result)
    }
    func cancel() { finished = true; cancellations.forEach { $0() }; cancellations = [] }
}

final class UpdateNetwork {
    let session: URLSession
    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 18
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }
    func fetch(_ channel: UpdateChannel, mode: UpdateMode = .normal, completion: @escaping (Result<UpdateRelease, Error>) -> Void) -> (() -> Void) {
        var request = URLRequest(url: channel.endpoint)
        request.setValue("EditDot/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if channel == .github { request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version") }
        let task = session.dataTask(with: request) { data, response, error in
            do {
                if let error = error { throw error }
                guard let http = response as? HTTPURLResponse, http.url?.scheme == "https" else { throw UpdateError.invalidResponse }
                if http.statusCode == 404 { throw UpdateError.noRelease }
                if http.statusCode == 403 || http.statusCode == 429 { throw UpdateError.rateLimited }
                guard http.statusCode == 200, let data = data else { throw UpdateError.unavailable }
                completion(.success(try ReleaseParser.parse(data, channel: channel, mode: mode)))
            } catch {
                completion(.failure(error as? UpdateError ?? (error is URLError ? UpdateError.unavailable : UpdateError.invalidResponse)))
            }
        }
        task.resume()
        return { task.cancel() }
    }
}

final class UpdateDownload: NSObject, URLSessionDownloadDelegate {
    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private let destination: URL
    private let progress: (Double?) -> Void
    private let completion: (Result<URL, Error>) -> Void
    private var result: Result<URL, Error>?
    private let limit: Int64 = 512 * 1024 * 1024
    init(url: URL, destination: URL, progress: @escaping (Double?) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        self.destination = destination; self.progress = progress; self.completion = completion
        super.init()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        task = session.downloadTask(with: url); task?.resume()
    }
    func cancel() { task?.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= limit, totalBytesExpectedToWrite <= limit else { result = .failure(UpdateError.invalidPackage); downloadTask.cancel(); return }
        let value = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : nil
        DispatchQueue.main.async { self.progress(value) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200, response.url?.scheme == "https" else { throw UpdateError.unavailable }
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(destination)
        } catch { result = .failure(error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = result ?? .failure(error ?? UpdateError.unavailable)
        session.finishTasksAndInvalidate()
        DispatchQueue.main.async { self.completion(outcome) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }
}
