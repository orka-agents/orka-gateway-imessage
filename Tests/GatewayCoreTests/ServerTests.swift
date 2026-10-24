import Foundation
@testable import GatewayCore
import Hummingbird
import HummingbirdTesting
import Testing

private struct Harness {
    let store: GatewayStore
    let backend = FakeBackend()
    let application: Application<RouterResponder<BasicRequestContext>>

    init(conformanceChat: String? = nil) throws {
        let configuration = try testConfiguration(conformanceChat: conformanceChat)
        store = try GatewayStore(path: temporaryStorePath())
        let deliveries = DeliveryService(
            configuration: configuration, store: store, backend: backend, logger: quietLogger, observer: { _ in }
        )
        application = Application(router: GatewayServer.router(configuration: configuration, store: store, deliveries: deliveries))
    }
}

private func authorized(_ token: String = outboundToken) -> HTTPFields {
    [.authorization: "Bearer \(token)", .contentType: "application/json"]
}

private func decode(_ response: TestResponse) throws -> DeliveryResponse {
    try JSONDecoder().decode(DeliveryResponse.self, from: Data(buffer: response.body))
}

private func deliver(_ client: some TestClientProtocol, _ body: Data) async throws -> (HTTPResponse.Status, DeliveryResponse?) {
    try await client.execute(uri: "/v1/deliveries", method: .post, headers: authorized(), body: ByteBuffer(bytes: body)) { response in
        (response.status, try? decode(response))
    }
}

struct ServerTests {
    @Test func protocolRoutesRequireTheOutboundToken() async throws {
        let harness = try Harness()
        try await harness.application.test(.router) { client in
            try await client.execute(uri: "/healthz", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.cacheControl] == "no-store")
                #expect(response.headers[.contentSecurityPolicy] == "default-src 'none'")
            }
            try await client.execute(uri: "/readyz", method: .get) { #expect($0.status == .ok) }
            for headers: HTTPFields in [[:], authorized("inbound-token"), [.authorization: "Basic \(outboundToken)"]] {
                try await client.execute(uri: "/v1/health", method: .get, headers: headers) { #expect($0.status == .unauthorized) }
                try await client.execute(uri: "/v1/capabilities", method: .get, headers: headers) { #expect($0.status == .unauthorized) }
                try await client.execute(uri: "/v1/deliveries", method: .post, headers: headers, body: ByteBuffer(bytes: deliveryBody())) {
                    #expect($0.status == .unauthorized)
                }
            }
            try await client.execute(uri: "/v1/health", method: .get, headers: authorized()) { #expect($0.status == .ok) }
            try await client.execute(uri: "/v1/capabilities", method: .get, headers: authorized()) { response in
                let capabilities = try JSONDecoder().decode(CapabilitiesResponse.self, from: Data(buffer: response.body))
                #expect(capabilities.protocolVersion == "orka.gateway.v1")
                #expect(capabilities.adapterName == "orka-gateway-imessage")
                #expect(capabilities.capabilities == Capabilities())
            }
        }
        #expect(harness.backend.sends.current.isEmpty)
    }

    @Test func deliverySendsOnceAndReplays() async throws {
        let harness = try Harness()
        try await harness.store.rememberReplyChat(testChat)
        try await harness.application.test(.router) { client in
            let (status, first) = try await deliver(client, deliveryBody())
            #expect(status == .ok)
            #expect(first?.status == .delivered)
            #expect(first?.providerMessageId?.hasPrefix("MSG-GUID-") == true)
            // Orka redelivers the same logical delivery with a new deliveryId.
            let (_, replay) = try await deliver(client, deliveryBody(deliveryID: "gdl-2"))
            #expect(replay == first)
            let (_, conflict) = try await deliver(client, deliveryBody(text: "different"))
            #expect(conflict == .rejected("delivery identity conflict"))
        }
        #expect(harness.backend.sends.current == [RecordedSend(text: "hello", chat: testChat)])
    }

    @Test func deliveryOnlyReachesAdmittedAllowlistedDirectChats() async throws {
        let harness = try Harness()
        let group = "iMessage;+;\(testHandle)"
        let stranger = "iMessage;-;+14155550000"
        for chat in [testChat, group, stranger] {
            try await harness.store.rememberReplyChat(chat)
        }
        let unadmitted = "iMessage;-;me@example.com"
        try await harness.application.test(.router) { client in
            let cases: [(Data, String)] = [
                (deliveryBody(contextID: unadmitted, replyTarget: unadmitted), "destination has no admitted inbound message"),
                (deliveryBody(contextID: group, replyTarget: group), "destination is not allowlisted"),
                (deliveryBody(contextID: stranger, replyTarget: stranger), "destination is not allowlisted"),
                (deliveryBody(accountID: "other-account"), "delivery routing mismatch"),
                (deliveryBody(threadID: "thread-1"), "delivery routing mismatch"),
                (deliveryBody(contextID: "iMessage;-;me@example.com"), "delivery routing mismatch"),
                (deliveryBody(contextID: "not-a-chat", replyTarget: "not-a-chat"), "delivery routing mismatch"),
                (deliveryBody(accountID: "conformance", contextID: "conformance", replyTarget: "conformance"),
                 "conformance chat is not configured"),
            ]
            for (index, (body, reason)) in cases.enumerated() {
                let body = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                var unique = body
                unique["idempotencyId"] = "gid-route-\(index)"
                let (status, response) = try await deliver(client, try JSONSerialization.data(withJSONObject: unique))
                #expect(status == .ok)
                #expect(response == .rejected(reason))
            }
        }
        #expect(harness.backend.sends.current.isEmpty)
    }

    @Test func conformanceRouteUsesTheConfiguredChat() async throws {
        let harness = try Harness(conformanceChat: testChat)
        try await harness.application.test(.router) { client in
            let (_, response) = try await deliver(
                client, deliveryBody(kind: "message", accountID: "conformance", contextID: "conformance", replyTarget: "conformance")
            )
            #expect(response?.status == .delivered)
        }
        #expect(harness.backend.sends.current == [RecordedSend(text: "hello", chat: testChat)])
    }

    @Test func deliveryOutcomesAreClassifiedAndOnlyUndispatchedSendsRetry() async throws {
        let harness = try Harness()
        try await harness.store.rememberReplyChat(testChat)
        harness.backend.outcomes.withLock {
            $0 = [.notDispatched("bridge down"), .delivered(providerMessageID: "bad id\n"), .unknown("timed out"), .rejected("bad")]
        }
        try await harness.application.test(.router) { client in
            let (_, notDispatched) = try await deliver(client, deliveryBody(idempotencyID: "a"))
            #expect(notDispatched == .retryable("iMessage send failed before dispatch"))
            // A retry of an undispatched send sends again.
            let (_, retried) = try await deliver(client, deliveryBody(idempotencyID: "a"))
            #expect(retried == .delivered(nil))

            let (_, unknown) = try await deliver(client, deliveryBody(idempotencyID: "b"))
            #expect(unknown == .rejected("iMessage delivery outcome is unknown"))
            // An unknown outcome is never retried.
            let (_, replayed) = try await deliver(client, deliveryBody(idempotencyID: "b"))
            #expect(replayed == unknown)

            let (_, rejected) = try await deliver(client, deliveryBody(idempotencyID: "c"))
            #expect(rejected == .rejected("iMessage rejected the send request"))
        }
        #expect(harness.backend.sends.current.count == 4)
    }

    @Test func deliveryBounds() async throws {
        let harness = try Harness()
        try await harness.store.rememberReplyChat(testChat)
        try await harness.application.test(.router) { client in
            let tooLarge = Data(repeating: UInt8(ascii: " "), count: GatewayProtocol.maxHTTPBodyBytes + 1)
            let (largeStatus, large) = try await deliver(client, tooLarge)
            #expect(largeStatus == .contentTooLarge)
            #expect(large == .rejected("invalid request body"))
            for body in [Data("{".utf8), deliveryBody(extra: ["unexpected": 1]), deliveryBody(kind: "message", text: String(repeating: "a", count: (16 << 10) + 1))] {
                let (status, response) = try await deliver(client, body)
                #expect(status == .badRequest)
                #expect(response == .rejected("invalid delivery"))
            }
        }
        #expect(harness.backend.sends.current.isEmpty)
    }

    @Test func concurrentRetriesOfOneDeliverySendOnce() async throws {
        let harness = try Harness()
        try await harness.store.rememberReplyChat(testChat)
        try await harness.application.test(.router) { client in
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0 ..< 8 {
                    group.addTask {
                        _ = try await deliver(client, deliveryBody(deliveryID: "gdl-\(index)"))
                    }
                }
                try await group.waitForAll()
            }
        }
        #expect(harness.backend.sends.current.count == 1)
    }
}
