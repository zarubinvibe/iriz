import Foundation
import Testing

@testable import IrizDictate

@Suite("Нативная цепочка скачивания модели голосов без сети")
struct SpeakerModelTransportTests {
    @Test("реальная цепочка URLSession доставляет прогресс и сохраняет файл после callback без сети")
    func configuredSessionDeliversDownloadProgress() async throws {
        let progress = SpeakerDownloadProgressProbe()
        let delegate = SpeakerModelDownloadDelegate(maximumBytes: 5) { progress.record($0) }
        let (file, response) = try await delegate.download(speakerProtocolRequest("success"),
                                                         configuration: speakerProtocolConfiguration())
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(response.statusCode == 200)
        #expect(try Data(contentsOf: file) == Data("model".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber).intValue
        #expect(permissions & 0o777 == 0o600)
        #expect(progress.values.contains { $0 > 0 })
        #expect(progress.values.allSatisfy { $0 >= 0 && $0 <= 5 })
        #expect(delegate.failure == nil)
    }

    @Test("реальная цепочка URLSession отвергает превышение лимита без ручного вызова delegate")
    func configuredSessionRejectsExcessiveDownload() async throws {
        let delegate = SpeakerModelDownloadDelegate(maximumBytes: 5, progress: { _ in })

        do {
            let (file, _) = try await delegate.download(speakerProtocolRequest("oversized"),
                                                       configuration: speakerProtocolConfiguration())
            try? FileManager.default.removeItem(at: file)
            Issue.record("Превышение лимита должно остановить нативную задачу скачивания")
        } catch let failure as SpeakerModelInstallFailure {
            #expect(failure == .integrityFailed)
        }

        #expect(delegate.failure == .integrityFailed)
    }

    @Test("предварительная отмена нативного загрузчика возвращает CancellationError без прогресса")
    func preCancelledTransportDoesNotStartDownload() async {
        let progress = SpeakerDownloadProgressProbe()
        let cancelled = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let delegate = SpeakerModelDownloadDelegate(maximumBytes: 5) { progress.record($0) }
            do {
                let (file, _) = try await delegate.download(speakerProtocolRequest("success"),
                                                           configuration: speakerProtocolConfiguration())
                try? FileManager.default.removeItem(at: file)
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }.value

        #expect(cancelled)
        #expect(progress.values.isEmpty)
    }

    @Test("ошибка URLProtocol завершает ожидание загрузчика исходной ошибкой")
    func configuredSessionCompletesTransportFailure() async throws {
        let delegate = SpeakerModelDownloadDelegate(maximumBytes: 5, progress: { _ in })

        do {
            let (file, _) = try await delegate.download(speakerProtocolRequest("failure"),
                                                       configuration: speakerProtocolConfiguration())
            try? FileManager.default.removeItem(at: file)
            Issue.record("Сбой транспорта не должен возвращать успешный результат")
        } catch let error as URLError {
            #expect(error.code == .networkConnectionLost)
        }
    }
}

private func speakerProtocolRequest(_ path: String) -> URLRequest {
    // Если protocolClasses случайно потеряется, схема не поддерживается: DNS и сети всё равно нет.
    URLRequest(url: URL(string: "iriz-speaker-fixture://download/" + path)!)
}

private func speakerProtocolConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpeakerFixtureURLProtocol.self]
    return configuration
}

private final class SpeakerFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "iriz-speaker-fixture"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        guard url.path != "/failure" else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let payload = Data((url.path == "/oversized" ? "models" : "model").utf8)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(payload.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload.prefix(2))
        client?.urlProtocol(self, didLoad: payload.dropFirst(2))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class SpeakerDownloadProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Int64] = []
    var values: [Int64] { lock.withLock { storedValues } }
    func record(_ value: Int64) { lock.withLock { storedValues.append(value) } }
}
