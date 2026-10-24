import Foundation
@testable import GatewayCore
import Testing

/// Answers every request with the status and body configured for the test.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var response: (status: Int, body: Data) = (202, Data())
    nonisolated(unsafe) static var requests: [URLRequest] = []

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.response.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct IngressTests {
    private let event = EventEnvelope(
        externalEventId: "MSG-1", accountId: "mac-messages", contextId: testChat, sender: EventSender(id: testHandle),
        text: "hi", replyTarget: testChat, occurredAt: Date(timeIntervalSince1970: 1_800_000_000.5)
    )

    private func ingress() -> HTTPEventIngress {
        HTTPEventIngress(
            url: URL(string: "http://127.0.0.1:8081/api/v1/gateways/orka/imessage/events")!,
            token: "inbound-token",
            protocolClasses: [StubProtocol.self]
        )
    }

    @Test func postsTheEventWithTheInboundToken() async throws {
        StubProtocol.requests = []
        StubProtocol.response = (202, Data(#"{"status":"accepted","eventId":"gev-1","state":"Queued"}"#.utf8))
        let admission = try await ingress().admit(event)
        #expect(admission == IngressAdmission(status: "accepted", eventID: "gev-1"))
        let request = try #require(StubProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer inbound-token")
        let body = try #require(request.httpBody ?? request.httpBodyStream.map { stream in
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            return data
        })
        let fields = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(fields["occurredAt"] as? String == "2027-01-15T08:00:00.500Z")
        #expect(fields["externalEventId"] as? String == "MSG-1")
        #expect(fields["replyTarget"] as? String == testChat)
    }

    @Test func admissionWithAnUnrecognizedBodyIsNotResent() async throws {
        StubProtocol.response = (202, Data("ok".utf8))
        #expect(try await ingress().admit(event).status == "unrecognized")
    }

    @Test(arguments: [400, 413, 422])
    func rejectedEventsArePermanent(status: Int) async {
        StubProtocol.response = (status, Data())
        await #expect(throws: IngressError.permanent(status: status)) { try await ingress().admit(event) }
    }

    @Test(arguments: [200, 302, 401, 404, 429, 500, 503])
    func otherStatusesAreRetried(status: Int) async {
        StubProtocol.response = (status, Data())
        await #expect(throws: IngressError.transient("Orka ingress returned HTTP \(status)")) { try await ingress().admit(event) }
    }

    @Test func oversizedResponsesAreRetried() async {
        StubProtocol.response = (202, Data(count: GatewayProtocol.maxAdapterResponseBytes + 1))
        await #expect(throws: IngressError.transient("Orka ingress response was invalid")) { try await ingress().admit(event) }
    }
}
