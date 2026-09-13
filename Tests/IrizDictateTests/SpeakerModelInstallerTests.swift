import CryptoKit
import Darwin
import Foundation
import Testing

@testable import IrizDictate

@Suite("Безопасная установка модели голосов без сети")
struct SpeakerModelInstallerTests {
    @Test("проверенные файлы публикуются с закрытыми правами, прежний кэш остаётся резервной копией")
    func successfulInstallKeepsBackupAndPrivatePermissions() async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let first = Data("first-model".utf8)
        let second = Data("second-model".utf8)
        let files = [speakerFixture("Fixture.mlmodelc/weights/weight.bin", first),
                     speakerFixture("parameters.json", second)]
        let probe = SpeakerFetchProbe()

        try await installSpeakerModelFiles(in: sandbox.models, files: files) { file, progress in
            await probe.record(file.relativePath)
            let data = file.relativePath == files[0].relativePath ? first : second
            let temporary = try sandbox.download(data)
            progress(Int64(data.count))
            return (temporary, speakerFixtureResponse())
        }

        #expect(await probe.paths == files.map(\.relativePath))
        #expect(try Data(contentsOf: sandbox.cache.appendingPathComponent(files[0].relativePath)) == first)
        #expect(try Data(contentsOf: sandbox.cache.appendingPathComponent(files[1].relativePath)) == second)
        let backups = try sandbox.backups()
        #expect(backups.count == 1)
        let backup = try #require(backups.first)
        #expect(try Data(contentsOf: backup.appendingPathComponent("previous.bin")) == sandbox.previous)
        for directory in [sandbox.cache,
                          sandbox.cache.appendingPathComponent("Fixture.mlmodelc"),
                          sandbox.cache.appendingPathComponent("Fixture.mlmodelc/weights")] {
            #expect(try speakerFileMode(directory) == 0o700)
        }
        for file in files {
            #expect(try speakerFileMode(sandbox.cache.appendingPathComponent(file.relativePath)) == 0o600)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.incoming.path).isEmpty)
        #expect(try sandbox.stagingDirectories().isEmpty)
    }

    @Test("HTTP-ошибка, неверная длина и неверный SHA-256 сохраняют прежний кэш",
          arguments: SpeakerBadPayload.allCases)
    func rejectedDownloadPreservesPreviousCache(_ kind: SpeakerBadPayload) async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let file = speakerFixture("Fixture.mlmodelc/model.bin", Data("model".utf8))

        do {
            try await installSpeakerModelFiles(in: sandbox.models, files: [file]) { _, progress in
                let temporary = try sandbox.download(kind.payload)
                progress(Int64(kind.payload.count))
                return (temporary, speakerFixtureResponse(status: kind == .httpError ? 404 : 200))
            }
            Issue.record("Повреждённый ответ не должен публиковаться")
        } catch let failure as SpeakerModelInstallFailure {
            #expect(failure == (kind == .httpError ? .invalidResponse : .integrityFailed))
        }

        try sandbox.expectPreviousCacheUnchanged()
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.incoming.path).isEmpty)
    }

    @Test("URL ответа, частичный HTTP-ответ и заявленная длина проверяются до публикации",
          arguments: SpeakerBadResponse.allCases)
    func invalidResponsePreservesPreviousCache(_ kind: SpeakerBadResponse) async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let payload = Data("model".utf8)
        let file = speakerFixture("model.bin", payload)

        do {
            try await installSpeakerModelFiles(in: sandbox.models, files: [file]) { _, _ in
                let url = URL(string: kind == .foreignHost
                              ? "https://attacker.example/model.bin" : "https://huggingface.co/fixture")!
                let response = HTTPURLResponse(url: url, statusCode: kind == .partialContent ? 206 : 200,
                                               httpVersion: "HTTP/1.1",
                                               headerFields: kind == .wrongLength ? ["Content-Length": "6"] : nil)!
                return (try sandbox.download(payload), response)
            }
            Issue.record("Недопустимый ответ не должен публиковаться")
        } catch let failure as SpeakerModelInstallFailure {
            #expect(failure == .invalidResponse)
        }

        try sandbox.expectPreviousCacheUnchanged()
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.incoming.path).isEmpty)
    }

    @Test("ошибка второго файла не публикует уже проверенный первый файл")
    func partialDownloadDoesNotReplaceCache() async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let payload = Data("model".utf8)
        let files = [speakerFixture("one.bin", payload), speakerFixture("two.bin", payload)]
        let probe = SpeakerFetchProbe()

        do {
            try await installSpeakerModelFiles(in: sandbox.models, files: files) { file, _ in
                await probe.record(file.relativePath)
                if file.relativePath == "two.bin" { throw URLError(.networkConnectionLost) }
                return (try sandbox.download(payload), speakerFixtureResponse())
            }
            Issue.record("Неполная загрузка не должна публиковаться")
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }

        #expect(await probe.paths == ["one.bin", "two.bin"])
        try sandbox.expectPreviousCacheUnchanged()
    }

    @Test("отмена после скачивания не заменяет кэш и не подменяется ошибкой целостности")
    func cancellationAfterFetchPreservesCache() async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let payload = Data("model".utf8)
        let file = speakerFixture("model.bin", payload)
        let cancelled = await Task {
            do {
                try await installSpeakerModelFiles(in: sandbox.models, files: [file]) { _, _ in
                    let temporary = try sandbox.download(payload)
                    withUnsafeCurrentTask { $0?.cancel() }
                    return (temporary, speakerFixtureResponse())
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(cancelled)
        try sandbox.expectPreviousCacheUnchanged()
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.incoming.path).isEmpty)
    }

    @Test("заранее отменённая установка не вызывает загрузчик")
    func preCancelledInstallDoesNotFetch() async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let file = speakerFixture("model.bin", Data("model".utf8))
        let probe = SpeakerFetchProbe()
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await installSpeakerModelFiles(in: sandbox.models, files: [file]) { file, _ in
                    await probe.record(file.relativePath)
                    throw URLError(.unknown)
                }
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(cancelled)
        #expect(await probe.paths.isEmpty)
        try sandbox.expectPreviousCacheUnchanged()
    }

    @Test("небезопасный путь манифеста отклоняется до загрузчика",
          arguments: ["../outside.bin", "/outside.bin", "model/../../outside.bin", "model/../file.bin"])
    func unsafeManifestPathDoesNotFetch(_ path: String) async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let probe = SpeakerFetchProbe()
        let file = speakerFixture(path, Data("model".utf8))

        do {
            try await installSpeakerModelFiles(in: sandbox.models, files: [file]) { file, _ in
                await probe.record(file.relativePath)
                throw URLError(.unknown)
            }
            Issue.record("Небезопасный путь должен быть отклонён")
        } catch let failure as SpeakerModelInstallFailure {
            #expect(failure == .invalidManifest)
        }

        #expect(await probe.paths.isEmpty)
        try sandbox.expectPreviousCacheUnchanged()
    }

    @Test("пустой манифест, дубли, недопустимый размер и SHA отклоняются до загрузчика",
          arguments: SpeakerBadManifest.allCases)
    func invalidManifestDoesNotFetch(_ kind: SpeakerBadManifest) async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let probe = SpeakerFetchProbe()
        let valid = speakerFixture("model.bin", Data("model".utf8))
        let files: [SpeakerModelFile]
        switch kind {
        case .empty: files = []
        case .duplicate: files = [valid, valid]
        case .zeroBytes: files = [SpeakerModelFile(relativePath: valid.relativePath, bytes: 0, sha256: valid.sha256)]
        case .excessiveBytes:
            files = [SpeakerModelFile(relativePath: valid.relativePath, bytes: 21_599_418, sha256: valid.sha256)]
        case .invalidDigest:
            files = [SpeakerModelFile(relativePath: valid.relativePath, bytes: valid.bytes,
                                      sha256: String(repeating: "z", count: 64))]
        }

        do {
            try await installSpeakerModelFiles(in: sandbox.models, files: files) { file, _ in
                await probe.record(file.relativePath)
                throw URLError(.unknown)
            }
            Issue.record("Некорректный манифест должен быть отклонён")
        } catch let failure as SpeakerModelInstallFailure {
            #expect(failure == .invalidManifest)
        }

        #expect(await probe.paths.isEmpty)
        try sandbox.expectPreviousCacheUnchanged()
    }

    @Test("символьная ссылка вместо скачанного файла не читается и не публикуется")
    func symlinkDownloadDoesNotReplaceCacheOrRemoveTarget() async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let payload = Data("model".utf8)
        let target = sandbox.root.appendingPathComponent("untouched.bin")
        try payload.write(to: target)
        let file = speakerFixture("model.bin", payload)

        do {
            try await installSpeakerModelFiles(in: sandbox.models, files: [file]) { _, _ in
                let link = sandbox.incoming.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                return (link, speakerFixtureResponse())
            }
            Issue.record("Ссылка не должна приниматься за скачанный файл")
        } catch is SpeakerModelInstallFailure {}

        #expect(try Data(contentsOf: target) == payload)
        try sandbox.expectPreviousCacheUnchanged()
    }

    @Test("FIFO вместо скачанного файла отклоняется без ожидания писателя")
    func fifoDownloadDoesNotBlockOrReplaceCache() async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let file = speakerFixture("model.bin", Data("model".utf8))
        let fifo = sandbox.incoming.appendingPathComponent("download.fifo")
        try #require(Darwin.mkfifo(fifo.path, mode_t(0o600)) == 0)

        do {
            try await installSpeakerModelFiles(in: sandbox.models, files: [file]) { _, _ in
                // FIFO намеренно не имеет писателя: обычный O_RDONLY здесь зависнет.
                return (fifo, speakerFixtureResponse())
            }
            Issue.record("FIFO не должен приниматься за скачанный файл")
        } catch let failure as SpeakerModelInstallFailure {
            #expect(failure == .integrityFailed)
        }

        try sandbox.expectPreviousCacheUnchanged()
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.incoming.path).isEmpty)
    }

    @Test("правильные байты через ссылку на внешний каталог не означают проверенный кэш")
    func symlinkCacheDirectoryCannotPassReadinessCheck() async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        try sandbox.seedPreviousCache()
        let payload = Data("model".utf8)
        let file = speakerFixture("Fixture.mlmodelc/model.bin", payload)
        let outside = sandbox.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let outsideFile = outside.appendingPathComponent("model.bin")
        try payload.write(to: outsideFile)
        let link = sandbox.cache.appendingPathComponent("Fixture.mlmodelc")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        do {
            try await installSpeakerModelFiles(in: sandbox.models, files: [file]) { _, _ in
                throw URLError(.networkConnectionLost)
            }
            Issue.record("Кэш через ссылку не должен проходить проверку готовности")
        } catch is SpeakerModelInstallFailure {
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }

        #expect(try Data(contentsOf: outsideFile) == payload)
        #expect(try Data(contentsOf: sandbox.cache.appendingPathComponent("previous.bin")) == sandbox.previous)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
        #expect(try sandbox.backups().isEmpty)
        #expect(try sandbox.stagingDirectories().isEmpty)
    }

    @Test("полностью проверенный кэш не скачивается и не переименовывается")
    func verifiedExistingCacheDoesNotFetch() async throws {
        let sandbox = try SpeakerInstallerSandbox()
        defer { sandbox.remove() }
        let payload = Data("model".utf8)
        let file = speakerFixture("Fixture.mlmodelc/model.bin", payload)
        let destination = sandbox.cache.appendingPathComponent(file.relativePath)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try payload.write(to: destination)
        let probe = SpeakerFetchProbe()

        try await installSpeakerModelFiles(in: sandbox.models, files: [file]) { file, _ in
            await probe.record(file.relativePath)
            throw URLError(.unknown)
        }

        #expect(await probe.paths.isEmpty)
        #expect(try Data(contentsOf: destination) == payload)
        #expect(try sandbox.backups().isEmpty)
        #expect(try sandbox.stagingDirectories().isEmpty)
    }

    @Test("официальный манифест содержит 21 файл, закреплённую ревизию и точный объём")
    func productionManifestIsPinnedAndDownloadURLsAreAllowlisted() throws {
        #expect(SpeakerModelManifest.repository == "FluidInference/speaker-diarization-coreml")
        #expect(SpeakerModelManifest.revision == "1ed7a662fdc7109e36d822db793ee6eebdaf8594")
        #expect(SpeakerModelManifest.files.count == 21)
        #expect(SpeakerModelManifest.files.reduce(Int64(0)) { $0 + $1.bytes } == 21_599_417)
        #expect(Set(SpeakerModelManifest.files.map(\.relativePath)).count == 21)
        for file in SpeakerModelManifest.files {
            let url = try speakerModelDownloadURL(for: file)
            #expect(url.scheme == "https")
            #expect(url.host == "huggingface.co")
            #expect(url.path == "/FluidInference/speaker-diarization-coreml/resolve/"
                    + SpeakerModelManifest.revision + "/" + file.relativePath)
            #expect(url.query == nil)
            #expect(file.bytes > 0)
            #expect(file.sha256.count == 64)
        }
        #expect(throws: SpeakerModelInstallFailure.self) {
            try speakerModelDownloadURL(for: speakerFixture("unlisted.bin", Data("model".utf8)))
        }
        let listed = try #require(SpeakerModelManifest.files.first)
        #expect(throws: SpeakerModelInstallFailure.self) {
            try speakerModelDownloadURL(for: SpeakerModelFile(relativePath: listed.relativePath,
                                                              bytes: listed.bytes,
                                                              sha256: String(repeating: "0", count: 64)))
        }
    }

    @Test("редирект принимает только HTTPS без credentials и порта на разрешённых доменах")
    func redirectsAreBoundedToOfficialHosts() throws {
        for value in ["https://huggingface.co/file", "https://cdn-lfs.huggingface.co/file",
                      "https://cas-bridge.xethub.hf.co/file?signature=fixture"] {
            #expect(speakerModelRedirectAllowed(try #require(URL(string: value))))
        }
        for value in ["http://huggingface.co/file", "https://huggingface.co.attacker.example/file",
                      "https://evilhuggingface.co/file", "https://attacker.example/file",
                      "https://user:password@huggingface.co/file", "https://huggingface.co:443/file",
                      "file:///tmp/model.bin"] {
            #expect(!speakerModelRedirectAllowed(try #require(URL(string: value))))
        }
    }

    @Test("обработчик скачивания останавливает превышение лимита и неверную заявленную длину без сети")
    func transportDelegateEnforcesExactByteBudget() {
        let cases: [(received: Int64, expected: Int64, rejected: Bool)] = [
            (5, 5, false), (5, -1, false), (6, 5, true), (0, 6, true), (0, 0, true),
        ]
        for fixture in cases {
            let session = URLSession(configuration: .ephemeral)
            defer { session.invalidateAndCancel() }
            // Только объект задачи: resume() не вызывается, сетевого запроса нет.
            let task = session.downloadTask(with: URL(string: "https://huggingface.co/fixture")!)
            let delegate = SpeakerModelDownloadDelegate(maximumBytes: 5, progress: { _ in })

            delegate.urlSession(session, downloadTask: task,
                                didWriteData: fixture.received,
                                totalBytesWritten: fixture.received,
                                totalBytesExpectedToWrite: fixture.expected)

            #expect(delegate.failure == (fixture.rejected ? .integrityFailed : nil))
        }
    }
}

enum SpeakerBadPayload: CaseIterable, Sendable {
    case httpError, tooShort, tooLong, wrongDigest

    var payload: Data {
        switch self {
        case .httpError: Data("model".utf8)
        case .tooShort: Data("mode".utf8)
        case .tooLong: Data("models".utf8)
        case .wrongDigest: Data("other".utf8)
        }
    }
}

enum SpeakerBadResponse: CaseIterable, Sendable {
    case foreignHost, partialContent, wrongLength
}

enum SpeakerBadManifest: CaseIterable, Sendable {
    case empty, duplicate, zeroBytes, excessiveBytes, invalidDigest
}

private actor SpeakerFetchProbe {
    private(set) var paths: [String] = []
    func record(_ path: String) { paths.append(path) }
}

private func speakerFixture(_ path: String, _ bytes: Data) -> SpeakerModelFile {
    SpeakerModelFile(relativePath: path, bytes: Int64(bytes.count),
                     sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
}

private func speakerFixtureResponse(status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://huggingface.co/fixture")!, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: nil)!
}

private func speakerFileMode(_ url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
}

private struct SpeakerInstallerSandbox: Sendable {
    let root: URL
    let previous = Data("previous-cache".utf8)
    var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    var cache: URL { models.appendingPathComponent("speaker-diarization", isDirectory: true) }
    var incoming: URL { root.appendingPathComponent("incoming", isDirectory: true) }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("iriz-speaker-install-test-" + UUID().uuidString, isDirectory: true)
        for directory in [root, models, incoming] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func download(_ bytes: Data) throws -> URL {
        let url = incoming.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        return url
    }

    func seedPreviousCache() throws {
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try previous.write(to: cache.appendingPathComponent("previous.bin"))
    }

    func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".iriz-model-backup-") }
    }

    func stagingDirectories() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: models, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".iriz-") && !$0.lastPathComponent.hasPrefix(".iriz-model-backup-") }
    }

    func expectPreviousCacheUnchanged() throws {
        #expect(try Data(contentsOf: cache.appendingPathComponent("previous.bin")) == previous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == ["previous.bin"])
        #expect(try backups().isEmpty)
        #expect(try stagingDirectories().isEmpty)
    }
}
