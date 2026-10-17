import Foundation
import XCTest
@testable import Bailey

final class BarkPushServiceTests: XCTestCase {
    func testParsesAndNormalizesMultipleBarkURLs() throws {
        let official = try XCTUnwrap(BarkDestination("  https://api.day.app/Example_123  "))
        XCTAssertEqual(official.url.absoluteString, "https://api.day.app/Example_123")
        XCTAssertEqual(official.key, "Example_123")
        XCTAssertEqual(official.displayName, "api.day.app · ••••_123")
        XCTAssertEqual(official.pushURL.absoluteString, "https://api.day.app/push")

        let selfHosted = try XCTUnwrap(BarkDestination("https://BARK.example.com:8443/Other-Key"))
        XCTAssertEqual(selfHosted.url.absoluteString, "https://bark.example.com:8443/Other-Key")
        XCTAssertEqual(selfHosted.pushURL.absoluteString, "https://bark.example.com:8443/push")

        let keyOnly = try XCTUnwrap(BarkDestination("Device_key1"))
        XCTAssertEqual(keyOnly.url.absoluteString, "https://api.day.app/Device_key1")
        XCTAssertEqual(BarkDestination("https://api.day.app/Device_key1"), keyOnly)
        XCTAssertEqual(BarkDestination("push")?.key, "push")

        for invalid in [
            "", " ", "foo bar", "https://bark.example.com/",
            "http://api.day.app/example", "https://example.com/key/extra",
            "https://evil.example@api.day.app/key", "https://api.day.app/key#fragment",
            "https://api.day.app/key?body=private", "abc/key",
            "https://api.day.app/%2f",
        ] {
            XCTAssertNil(BarkDestination(invalid), invalid)
        }
    }

    func testRequestUsesCorrectServerAndNeverIncludesKeyInURL() throws {
        let destination = try XCTUnwrap(BarkDestination("https://bark.example.org/ExampleKey"))
        let request = try BarkPushService.makeRequest(
            title: "测试项目", message: "Codex 已完成\n需要继续", destination: destination
        )
        XCTAssertEqual(request.url?.absoluteString, "https://bark.example.org/push")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 10)

        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(json["device_key"], "ExampleKey")
        XCTAssertEqual(json["title"], "测试项目")
        XCTAssertEqual(json["body"], "Codex 已完成\n需要继续")
        XCTAssertEqual(json["group"], "Bailey")
    }

    func testRequestBoundsLongCombiningCharacterSequences() throws {
        let destination = try XCTUnwrap(BarkDestination("https://api.day.app/key"))
        let complexCharacter = "a" + String(repeating: "\u{0301}", count: 25_000)
        let request = try BarkPushService.makeRequest(
            title: complexCharacter, message: complexCharacter, destination: destination
        )
        let data = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertLessThanOrEqual(try XCTUnwrap(json["title"]).unicodeScalars.count, 120)
        XCTAssertLessThanOrEqual(try XCTUnwrap(json["body"]).unicodeScalars.count, 1_000)
        XCTAssertLessThan(data.count, 8_192)
    }

    func testServerErrorsAreNotTreatedAsSuccessfulDelivery() throws {
        let url = try XCTUnwrap(URL(string: "https://api.day.app/push"))
        func response(_ code: Int) throws -> HTTPURLResponse {
            try XCTUnwrap(HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil))
        }
        XCTAssertNoThrow(try BarkPushService.validateResponse(
            try response(200), data: Data(#"{"code":200,"message":"success"}"#.utf8)
        ))
        XCTAssertThrowsError(try BarkPushService.validateResponse(
            try response(500), data: Data(#"{"code":200}"#.utf8)
        ))
        XCTAssertThrowsError(try BarkPushService.validateResponse(
            try response(200), data: Data(#"{"code":400,"message":"invalid key"}"#.utf8)
        ))
        XCTAssertThrowsError(try BarkPushService.validateResponse(
            try response(200), data: Data(#"not json"#.utf8)
        ))
    }

    func testMultipleDestinationsContinueAfterOneServerFails() async throws {
        let destinations = try [
            XCTUnwrap(BarkDestination("https://ok.example/one")),
            XCTUnwrap(BarkDestination("https://fail.example/two")),
            XCTUnwrap(BarkDestination("https://other.example/three")),
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockBarkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let result = await BarkPushService.deliver(
            to: destinations, title: "Bailey", message: "completed", using: session
        )
        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.accepted, 2)
        XCTAssertEqual(result.failed, 1)
    }
}

private final class MockBarkURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: url.host == "fail.example" ? 500 : 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self, didLoad: Data(#"{"code":200,"message":"success"}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
