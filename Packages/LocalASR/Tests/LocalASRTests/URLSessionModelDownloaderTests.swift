import Foundation
import XCTest
@testable import LocalASR

private final class ModelDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Response = (HTTPURLResponse, Data)
    nonisolated(unsafe) static var response: Response?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let response = Self.response else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response.0, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class URLSessionModelDownloaderTests: XCTestCase {
    private let url = URL(string: "https://huggingface.co/test/model.bin")!

    override func tearDown() {
        ModelDownloadURLProtocol.response = nil
    }

    private func downloader() -> URLSessionModelDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelDownloadURLProtocol.self]
        return URLSessionModelDownloader(configuration: configuration)
    }

    func testDefaultConfigurationStartsExplicitDownloadsOnEveryNetwork() throws {
        let instance = URLSessionModelDownloader()
        let configuration = try XCTUnwrap(
            Mirror(reflecting: instance).descendant("configuration") as? URLSessionConfiguration
        )

        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertTrue(configuration.allowsExpensiveNetworkAccess)
        XCTAssertTrue(configuration.allowsConstrainedNetworkAccess)
    }

    private func response(status: Int = 200, length: Int, body: Data) -> ModelDownloadURLProtocol.Response {
        let http = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": String(length)]
        )!
        return (http, body)
    }

    func testExactHTTPSResponseIsAccepted() async throws {
        let body = Data("model".utf8)
        ModelDownloadURLProtocol.response = response(length: body.count, body: body)

        let file = try await downloader().download(from: url, expectedBytes: Int64(body.count)) { _ in }
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(try Data(contentsOf: file), body)
    }

    func testHTTPFailureIsNotPromotedAsModelData() async {
        let body = Data("server error".utf8)
        ModelDownloadURLProtocol.response = response(status: 503, length: body.count, body: body)

        do {
            _ = try await downloader().download(from: url, expectedBytes: Int64(body.count)) { _ in }
            XCTFail("HTTP 503 \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{0441}\u{0447}\u{0438}\u{0442}\u{0430}\u{0442}\u{044C}\u{0441}\u{044F} \u{043C}\u{043E}\u{0434}\u{0435}\u{043B}\u{044C}\u{044E}")
        } catch {
            XCTAssertEqual(error as? ModelDownloadError, .httpStatus(503))
        }
    }

    func testOversizedBodyStopsBeforePromotion() async {
        let body = Data(repeating: 0x41, count: 32)
        ModelDownloadURLProtocol.response = response(length: body.count, body: body)

        do {
            _ = try await downloader().download(from: url, expectedBytes: 8) { _ in }
            XCTFail("Oversized response \u{043D}\u{0435} \u{0434}\u{043E}\u{043B}\u{0436}\u{0435}\u{043D} \u{043F}\u{043E}\u{043F}\u{0430}\u{0441}\u{0442}\u{044C} \u{0432} staging")
        } catch {
            guard case let .unexpectedSize(expected, actual) = error as? ModelDownloadError else {
                return XCTFail("\u{041E}\u{0436}\u{0438}\u{0434}\u{0430}\u{043B}\u{0430}\u{0441}\u{044C} unexpectedSize, \u{043F}\u{043E}\u{043B}\u{0443}\u{0447}\u{0435}\u{043D}\u{043E}: \(error)")
            }
            XCTAssertEqual(expected, 8)
            XCTAssertGreaterThan(actual, 8)
        }
    }
}

/// Continuing a dropped transfer instead of starting it over.
///
/// Measured on a real flaky link: the 445 MB encoder reached 415 MB, the
/// connection dropped, and the retry started from zero. Six minutes of download
/// thrown away, and on a link that drops regularly the install never finishes.
final class DownloadResumeTests: XCTestCase {
    private let url = URL(string: "https://huggingface.co/test/model.bin")!

    override func tearDown() {
        FailingURLProtocol.reset()
    }

    private func downloader() -> URLSessionModelDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocol.self]
        return URLSessionModelDownloader(configuration: configuration)
    }

    /// A drop with nothing saved is handed straight up, without re-dialling.
    ///
    /// The layer above already retries and also knows about the mirror. Dialling
    /// again here would multiply attempts without saving a single byte.
    func testFailureWithoutResumeDataIsNotRetriedHere() async {
        FailingURLProtocol.failEveryRequest = true

        _ = try? await downloader().download(from: url, expectedBytes: 100) { _ in }

        XCTAssertEqual(
            FailingURLProtocol.requestCount, 1,
            "nothing on disk to continue — the retry belongs to the layer that knows the mirror"
        )
    }

    /// A cancel carries nothing forward: continuing later would continue
    /// against the user's direct command.
    func testCancellationIsReportedAsCancellation() async {
        FailingURLProtocol.failWith = URLError(.cancelled)

        do {
            _ = try await downloader().download(from: url, expectedBytes: 100) { _ in }
            XCTFail("expected a failure")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error, .cancelled)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// A refused host stays one attempt: retrying it is exactly what the
    /// network policy forbids.
    func testDisallowedURLNeverReachesTheNetwork() async {
        FailingURLProtocol.failEveryRequest = true
        let outside = URL(string: "https://evil.example.com/model.bin")!

        do {
            _ = try await downloader().download(from: outside, expectedBytes: 100) { _ in }
            XCTFail("expected a failure")
        } catch let error as ModelDownloadError {
            guard case .unapprovedURL = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertEqual(FailingURLProtocol.requestCount, 0, "not a single byte leaves for a refused host")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private final class FailingURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var failEveryRequest = false
    nonisolated(unsafe) static var failWith: (any Error)?
    nonisolated(unsafe) static private(set) var requestCount = 0
    nonisolated(unsafe) private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        failEveryRequest = false
        failWith = nil
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requestCount += 1
        let error = Self.failWith ?? URLError(.networkConnectionLost)
        Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}
