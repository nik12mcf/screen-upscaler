import Foundation
import Security

/// Minimal fal.ai REST client for the hosted FlashVSR model: upload a file to
/// fal storage, run it through the queue, download the result.
///
/// FlashVSR itself needs an NVIDIA GPU (CUDA + a CUDA-only sparse attention
/// kernel), so on a Mac the only way to use it is remotely.
///
/// Protocol per fal's own clients (fal-js storage.ts, queue docs):
///   POST rest.fal.ai/storage/upload/initiate      -> {upload_url, file_url}, then PUT bytes
///   POST queue.fal.run/<endpoint>                 -> {status_url, response_url, cancel_url}
///   GET  status_url                               -> IN_QUEUE | IN_PROGRESS | COMPLETED
final class FalClient {

    static let endpoint = "fal-ai/flashvsr/upscale/video"
    /// $ per megapixel of output video (width × height × frames), as listed by fal.
    static let pricePerMegapixel = 0.0005

    enum FalError: LocalizedError {
        case noKey, badKey, http(Int, String), malformed(String), failed(String)
        var errorDescription: String? {
            switch self {
            case .noKey: "No fal.ai API key set."
            case .badKey: "fal.ai rejected the API key."
            case .http(let code, let body): "fal.ai returned HTTP \(code): \(body)"
            case .malformed(let what): "Unexpected response from fal.ai (\(what))."
            case .failed(let why): "FlashVSR failed: \(why)"
            }
        }
    }

    enum Status {
        case queued(position: Int?)
        case running
        case completed(error: String?)
    }

    struct Job {
        let statusURL: URL
        let responseURL: URL
        let cancelURL: URL
    }

    private let key: String
    private let session = URLSession(configuration: .default)

    init(key: String) { self.key = key }

    // MARK: Storage

    private static let restURL = "https://rest.fal.ai"
    private static let multipartThreshold = 90 * 1024 * 1024
    private static let chunkSize = 10 * 1024 * 1024

    /// Uploads a local file and returns its fal-hosted URL.
    func upload(_ file: URL, contentType: String,
                progress: @escaping (Double) -> Void) async throws -> String {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        let body: [String: Any] = ["content_type": contentType, "file_name": file.lastPathComponent]

        if size <= Self.multipartThreshold {
            let initiated = try await json("POST",
                "\(Self.restURL)/storage/upload/initiate?storage_type=fal-cdn-v3", body: body)
            guard let uploadURL = (initiated["upload_url"] as? String).flatMap(URL.init(string:)),
                  let fileURL = initiated["file_url"] as? String else {
                throw FalError.malformed("upload initiate")
            }
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.upload(
                for: request, fromFile: file, delegate: UploadProgress(progress))
            try check(response, data)
            return fileURL
        }

        // Multipart: 10 MB parts PUT to <upload_url path>/<n>, then /complete.
        let initiated = try await json("POST",
            "\(Self.restURL)/storage/upload/initiate-multipart?storage_type=fal-cdn-v3", body: body)
        guard let base = (initiated["upload_url"] as? String).flatMap({ URLComponents(string: $0) }),
              let fileURL = initiated["file_url"] as? String else {
            throw FalError.malformed("multipart initiate")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var parts: [[String: Any]] = []
        var sent = 0
        var number = 1
        while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            var part = base
            part.path += "/\(number)"
            guard let url = part.url else { throw FalError.malformed("part url") }
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            let (data, response) = try await session.upload(for: request, from: chunk)
            try check(response, data)
            let etag = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["etag"] as? String
                ?? (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            guard let etag else { throw FalError.malformed("part etag") }
            parts.append(["partNumber": number, "etag": etag])
            sent += chunk.count
            progress(Double(sent) / Double(max(size, 1)))
            number += 1
        }
        var complete = base
        complete.path += "/complete"
        guard let completeURL = complete.url else { throw FalError.malformed("complete url") }
        _ = try await json("POST", completeURL.absoluteString, body: ["parts": parts], auth: false)
        return fileURL
    }

    /// Best effort: uploads are public URLs, so remove them once used.
    func delete(fileURL: String) async {
        _ = try? await json("POST", "\(Self.restURL)/storage/files/delete", body: ["file_url": fileURL])
    }

    // MARK: Queue

    func submit(_ input: [String: Any]) async throws -> Job {
        let r = try await json("POST", "https://queue.fal.run/\(Self.endpoint)", body: input)
        guard let status = (r["status_url"] as? String).flatMap(URL.init(string:)),
              let response = (r["response_url"] as? String).flatMap(URL.init(string:)),
              let cancel = (r["cancel_url"] as? String).flatMap(URL.init(string:)) else {
            throw FalError.malformed("submit")
        }
        return Job(statusURL: status, responseURL: response, cancelURL: cancel)
    }

    func status(_ job: Job) async throws -> Status {
        let r = try await json("GET", job.statusURL.absoluteString)
        switch r["status"] as? String {
        case "IN_QUEUE": return .queued(position: r["queue_position"] as? Int)
        case "IN_PROGRESS": return .running
        case "COMPLETED": return .completed(error: r["error"] as? String)
        default: throw FalError.malformed("status \(r["status"] ?? "missing")")
        }
    }

    /// URL of the finished video.
    func result(_ job: Job) async throws -> URL {
        let r = try await json("GET", job.responseURL.absoluteString)
        guard let video = r["video"] as? [String: Any],
              let url = (video["url"] as? String).flatMap(URL.init(string:)) else {
            if let detail = r["detail"] { throw FalError.failed("\(detail)") }
            throw FalError.malformed("result")
        }
        return url
    }

    func cancel(_ job: Job) async {
        _ = try? await json("PUT", job.cancelURL.absoluteString)
    }

    func download(_ url: URL, to destination: URL,
                  progress: @escaping (Double) -> Void) async throws {
        let (temp, response) = try await session.download(
            for: URLRequest(url: url), delegate: DownloadProgress(progress))
        try check(response, nil)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
    }

    // MARK: HTTP

    @discardableResult
    private func json(_ method: String, _ url: String, body: Any? = nil,
                      auth: Bool = true) async throws -> [String: Any] {
        guard let u = URL(string: url) else { throw FalError.malformed("url") }
        var request = URLRequest(url: u)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if auth { request.setValue("Key \(key)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try check(response, data)
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func check(_ response: URLResponse, _ data: Data?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 { throw FalError.badKey }
        guard (200..<300).contains(http.statusCode) else {
            let text = data.flatMap { String(data: $0.prefix(300), encoding: .utf8) } ?? ""
            throw FalError.http(http.statusCode, text)
        }
    }

    // MARK: API key (Keychain, falling back to $FAL_KEY)

    private static let keychainService = "io.jeffersonst.screenupscaler.fal"

    static var storedKey: String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecReturnData as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty {
            return key
        }
        let env = ProcessInfo.processInfo.environment["FAL_KEY"]
        return env?.isEmpty == false ? env : nil
    }

    static func storeKey(_ key: String) {
        let match: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService]
        SecItemDelete(match as CFDictionary)
        guard !key.isEmpty else { return }
        var add = match
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

private final class UploadProgress: NSObject, URLSessionTaskDelegate {
    private let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

private final class DownloadProgress: NSObject, URLSessionDownloadDelegate {
    private let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
