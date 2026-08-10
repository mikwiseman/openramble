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
