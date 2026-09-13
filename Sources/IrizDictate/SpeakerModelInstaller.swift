import CryptoKit
import Darwin
import FluidAudio
import Foundation

/// Только явная загрузка моделей говорящих; запись и текст сюда не передаются.
public let speakerModelDownloadBytes: Int64 = 21_599_417
public let speakerModelRepositoryRevision = "1ed7a662fdc7109e36d822db793ee6eebdaf8594"

public enum SpeakerModelInstallFailure: Error, Equatable {
    case alreadyRunning, invalidManifest, invalidResponse, integrityFailed, unsafeCache
}

struct SpeakerModelFile: Equatable, Sendable {
    let relativePath: String
    let bytes: Int64
    let sha256: String
}

enum SpeakerModelManifest {
    static let repository = "FluidInference/speaker-diarization-coreml"
    static let revision = speakerModelRepositoryRevision
    // Проверены по закреплённому HF tree и фактическим байтам 13.09.2026.
    static let files: [SpeakerModelFile] = [
        SpeakerModelFile(relativePath: "Embedding.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "8d6706436639b53830b4dbe8aaf9c9a843f7f582d63e16f3cb8bb7c6ccd58682"),
        SpeakerModelFile(relativePath: "Embedding.mlmodelc/coremldata.bin", bytes: 704, sha256: "4a705bac27d151d9642f37609296042a15602a42253039e0921dc9e75da7e004"),
        SpeakerModelFile(relativePath: "Embedding.mlmodelc/metadata.json", bytes: 2818, sha256: "1854371eb6b438fb8aeac96afb45c999af7902581c06afdfcd7ff3cb1ce66be5"),
        SpeakerModelFile(relativePath: "Embedding.mlmodelc/model.mil", bytes: 78432, sha256: "22fa958aef72a561c21f874a07cbdcd30fdf40ee961c0bc2fb67c119273b46d3"),
        SpeakerModelFile(relativePath: "Embedding.mlmodelc/weights/weight.bin", bytes: 13412288, sha256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b"),
        SpeakerModelFile(relativePath: "FBank.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "0e8bd3a8b82ac123580989f490e4d9245127c535857630b543311268accc3f0a"),
        SpeakerModelFile(relativePath: "FBank.mlmodelc/coremldata.bin", bytes: 853, sha256: "57ac436bb0671cbb5527a339134d695f752eb77f7a18966b93c6835335595759"),
        SpeakerModelFile(relativePath: "FBank.mlmodelc/metadata.json", bytes: 3409, sha256: "2623785f5d186893b82d01e84aa33a7704ef763c3309e02055f22dc9d871ce9a"),
        SpeakerModelFile(relativePath: "FBank.mlmodelc/model.mil", bytes: 15667, sha256: "27aaeb21569e81bdbe2eef87789f50a37cfea800039bd134448a9417de2f30ed"),
        SpeakerModelFile(relativePath: "FBank.mlmodelc/weights/weight.bin", bytes: 1776896, sha256: "9e83fdd3ea78064b078069e4d9141603c61c47a27fd19e7e3142ff7476f8db36"),
        SpeakerModelFile(relativePath: "PldaRho.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "8940ea6044dbcbefa22da8cc41e0b485e1fb5ed89aecaf37c6e0c483a97ddcd7"),
        SpeakerModelFile(relativePath: "PldaRho.mlmodelc/coremldata.bin", bytes: 763, sha256: "4d9741477f721c79b09fcdfe455110c4b7d4272e2de3496bf1729d966d3ee418"),
        SpeakerModelFile(relativePath: "PldaRho.mlmodelc/metadata.json", bytes: 2749, sha256: "b314cf25a93e46b4076883a6f5a2f8848b73c3851bd9d36074d067f35a1c7945"),
        SpeakerModelFile(relativePath: "PldaRho.mlmodelc/model.mil", bytes: 7613, sha256: "83aee2e5310d19b5f202aea97d07a0e12102556d1b32ef3ed08b36f7f9725041"),
        SpeakerModelFile(relativePath: "PldaRho.mlmodelc/weights/weight.bin", bytes: 200192, sha256: "80f7d229202636d372428c90596f11a91545f07da77259f07153aaf225914a36"),
        SpeakerModelFile(relativePath: "Segmentation.mlmodelc/analytics/coremldata.bin", bytes: 243, sha256: "64265f8e7ad41a5f68d630c15288c2499cca5892ad49e20096819cdeac004cdb"),
        SpeakerModelFile(relativePath: "Segmentation.mlmodelc/coremldata.bin", bytes: 812, sha256: "ea51481b8bd3e496ad3cf16f066ddaa37f20e8772eaac76b3393c28de20e06bc"),
        SpeakerModelFile(relativePath: "Segmentation.mlmodelc/metadata.json", bytes: 3410, sha256: "88dbf0b07208fe142e1729c2b4c974ad3599fcb2ae5d5f18fce782b225384124"),
        SpeakerModelFile(relativePath: "Segmentation.mlmodelc/model.mil", bytes: 43063, sha256: "d37e4ce30b406a6b34f765f769b9baed3178cc0c2b2e299c641daa43a052dd3f"),
        SpeakerModelFile(relativePath: "Segmentation.mlmodelc/weights/weight.bin", bytes: 5959360, sha256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2"),
        SpeakerModelFile(relativePath: "plda-parameters.json", bytes: 89416, sha256: "38ee28d4269c076cef254ee760bbd811f0738a92e0f01f9699ad372828c5de8f"),
    ]
}

public actor SpeakerModelInstaller {
    public static let shared = SpeakerModelInstaller()
    public private(set) var isRunning = false
    private init() {}

    /// Проверяет закреплённые байты на диске, без MLModel и без сети.
    public func isInstalled(modelsDirectory: URL? = nil) async -> Bool {
        let root = modelsDirectory ?? OfflineDiarizerModels.defaultModelsDirectory()
        return (try? speakerModelVerifyCache(in: root, files: SpeakerModelManifest.files)) == true
    }

    /// Родитель кэша speaker-diarization. Вызывается только отдельным действием человека.
    public func install(modelsDirectory: URL? = nil,
                        progress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        guard !isRunning else { throw SpeakerModelInstallFailure.alreadyRunning }
        isRunning = true
        defer { isRunning = false }
        try await installSpeakerModelFiles(
            in: modelsDirectory ?? OfflineDiarizerModels.defaultModelsDirectory(),
            files: SpeakerModelManifest.files, progress: progress
        ) { file, received in
            var request = URLRequest(url: try speakerModelDownloadURL(for: file))
            request.timeoutInterval = 60
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let delegate = SpeakerModelDownloadDelegate(maximumBytes: file.bytes, progress: received)
            return try await delegate.download(request)
        }
    }
}

typealias SpeakerModelFetch = @Sendable (
    SpeakerModelFile, @escaping @Sendable (Int64) -> Void
) async throws -> (URL, HTTPURLResponse)

/// Fetch подменяется только в synthetic tests. Старый кэш не затрагивается до
/// проверки ВСЕХ файлов. Публикация использует существующий rename+backup helper.
func installSpeakerModelFiles(in modelsDirectory: URL, files: [SpeakerModelFile],
                              progress: @escaping @Sendable (Double) -> Void = { _ in },
                              fetch: SpeakerModelFetch) async throws {
    try Task.checkCancellation()
    guard modelsDirectory.isFileURL, !files.isEmpty,
          Set(files.map(\.relativePath)).count == files.count else {
        throw SpeakerModelInstallFailure.invalidManifest
    }
    for file in files {
        let components = file.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !file.relativePath.contains("\\"), !file.relativePath.contains("\0"),
              file.bytes > 0, file.bytes <= speakerModelDownloadBytes,
              file.sha256.count == 64, file.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw SpeakerModelInstallFailure.invalidManifest
        }
    }
    let manager = FileManager.default
    let cache = modelsDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    try speakerModelRequireDirectoryIfPresent(modelsDirectory)
    try speakerModelRequireDirectoryIfPresent(cache)
    if (try? speakerModelVerifyCache(in: modelsDirectory, files: files)) == true {
        try Task.checkCancellation()
        progress(1)
        return
    }
    try Task.checkCancellation()
    try manager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
    let staging = modelsDirectory.appendingPathComponent(".iriz-speaker-download-" + UUID().uuidString,
                                                        isDirectory: true)
    try manager.createDirectory(at: staging, withIntermediateDirectories: false,
                                attributes: [.posixPermissions: 0o700])
    defer { try? manager.removeItem(at: staging) }
    let total = files.reduce(Int64(0)) { $0 + $1.bytes }
    var completed: Int64 = 0
    progress(0)
    for file in files {
        try Task.checkCancellation()
        let preceding = completed
        let (temporary, response) = try await fetch(file) { received in
            progress(Double(preceding + min(file.bytes, max(0, received))) / Double(total))
        }
        defer { try? manager.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard response.statusCode == 200, let url = response.url, speakerModelRedirectAllowed(url),
              response.expectedContentLength < 0 || response.expectedContentLength == file.bytes else {
            throw SpeakerModelInstallFailure.invalidResponse
        }
        try speakerModelVerifyFile(temporary, file: file)
        let target = staging.appendingPathComponent(file.relativePath)
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        try manager.moveItem(at: temporary, to: target)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        completed += file.bytes
    }
    try Task.checkCancellation()
    for file in files {
        try speakerModelVerifyFile(staging.appendingPathComponent(file.relativePath), file: file)
    }
    try Task.checkCancellation()
    // Не открываем окно отмены между backup и rename; helper восстановит старое при отказе.
    try publishSpeechModelCache(from: staging, to: cache)
    progress(1)
}

func speakerModelDownloadURL(for file: SpeakerModelFile) throws -> URL {
    guard SpeakerModelManifest.files.contains(file),
          let url = URL(string: "https://huggingface.co/\(SpeakerModelManifest.repository)/resolve/\(SpeakerModelManifest.revision)/\(file.relativePath)") else {
        throw SpeakerModelInstallFailure.invalidManifest
    }
    return url
}

func speakerModelRedirectAllowed(_ url: URL) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil,
          let host = url.host?.lowercased() else { return false }
    return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
}

private func speakerModelRequireDirectoryIfPresent(_ url: URL) throws {
    let attributes: [FileAttributeKey: Any]
    do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return }
    guard attributes[.type] as? FileAttributeType == .typeDirectory else {
        throw SpeakerModelInstallFailure.unsafeCache
    }
}

private func speakerModelVerifyCache(in root: URL, files: [SpeakerModelFile]) throws -> Bool {
    try Task.checkCancellation()
    guard root.isFileURL else { return false }
    try speakerModelRequireDirectoryIfPresent(root)
    let cache = root.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    try speakerModelRequireDirectoryIfPresent(cache)
    for file in files {
        var parent = cache
        for component in file.relativePath.split(separator: "/").dropLast() {
            parent.appendPathComponent(String(component), isDirectory: true)
            try speakerModelRequireDirectoryIfPresent(parent)
        }
        try speakerModelVerifyFile(cache.appendingPathComponent(file.relativePath), file: file)
    }
    return true
}

private func speakerModelVerifyFile(_ url: URL, file: SpeakerModelFile) throws {
    guard url.isFileURL else { throw SpeakerModelInstallFailure.integrityFailed }
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw SpeakerModelInstallFailure.integrityFailed }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var attributes = stat()
    guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
          attributes.st_size == file.bytes else { throw SpeakerModelInstallFailure.integrityFailed }
    var hash = SHA256()
    var received: Int64 = 0
    while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
        try Task.checkCancellation()
        received += Int64(data.count)
        guard received <= file.bytes else { throw SpeakerModelInstallFailure.integrityFailed }
        hash.update(data: data)
    }
    guard received == file.bytes,
          hash.finalize().map({ String(format: "%02x", $0) }).joined() == file.sha256 else {
        throw SpeakerModelInstallFailure.integrityFailed
    }
}

final class SpeakerModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maximumBytes: Int64
    let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var rejected: SpeakerModelInstallFailure?
    private var continuation: CheckedContinuation<(URL, HTTPURLResponse), Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    var failure: SpeakerModelInstallFailure? { lock.withLock { rejected } }

    init(maximumBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.maximumBytes = maximumBytes
        self.progress = progress
    }

    /// Session-level delegate: async download(for:delegate:) не доставляет
    /// didWriteData в этой Foundation. Явная задача даёт реальные байты и отмену.
    func download(_ request: URLRequest,
                  configuration: URLSessionConfiguration = .ephemeral) async throws -> (URL, HTTPURLResponse) {
        try Task.checkCancellation()
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                let shouldCancel = lock.withLock {
                    self.continuation = continuation
                    self.task = task
                    return cancelled
                }
                if shouldCancel {
                    complete(.failure(CancellationError()))
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            let task = self.lock.withLock {
                self.cancelled = true
                return self.task
            }
            task?.cancel()
        }
    }

    private func complete(_ result: Result<(URL, HTTPURLResponse), Error>) {
        let receiver = lock.withLock {
            let receiver = continuation
            continuation = nil
            task = nil
            return receiver
        }
        if let receiver { receiver.resume(with: result) }
        else if case .success(let (url, _)) = result { try? FileManager.default.removeItem(at: url) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        do {
            if let failure { throw failure }
            if lock.withLock({ cancelled }) { throw CancellationError() }
            guard let response = downloadTask.response as? HTTPURLResponse,
                  response.statusCode == 200 else { throw SpeakerModelInstallFailure.invalidResponse }
            // URLSession удаляет location после callback; сохраняем только до
            // передачи в private staging. Helper удалит файл при любом отказе.
            let preserved = FileManager.default.temporaryDirectory
                .appendingPathComponent("iriz-speaker-file-" + UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: preserved)
            do {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: preserved.path)
            } catch {
                try? FileManager.default.removeItem(at: preserved)
                throw error
            }
            complete(.success((preserved, response)))
        } catch { complete(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure { complete(.failure(failure)) }
        else if lock.withLock({ cancelled }) { complete(.failure(CancellationError())) }
        else { complete(.failure(error ?? SpeakerModelInstallFailure.invalidResponse)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= maximumBytes,
              totalBytesExpectedToWrite < 0 || totalBytesExpectedToWrite == maximumBytes else {
            lock.withLock { rejected = .integrityFailed }
            downloadTask.cancel()
            return
        }
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, speakerModelRedirectAllowed(url) else {
            lock.withLock { rejected = .invalidResponse }
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
