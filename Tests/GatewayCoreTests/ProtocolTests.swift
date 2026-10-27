import Foundation
@testable import GatewayCore
import Testing

func deliveryBody(
    deliveryID: String = "gdl-1",
    idempotencyID: String = "gid-1",
    kind: String = "final",
    accountID: String = "mac-messages",
    contextID: String = testChat,
    replyTarget: String = testChat,
    threadID: String? = nil,
    text: String = "hello",
    extra: [String: Any] = [:]
) -> Data {
    var fields: [String: Any] = [
        "protocolVersion": GatewayProtocol.version, "deliveryId": deliveryID, "idempotencyId": idempotencyID,
        "originatingEventId": "gev-1", "kind": kind, "accountId": accountID, "contextId": contextID,
        "replyTarget": replyTarget, "text": text, "taskRef": ["namespace": "orka", "name": "task-1"],
    ]
    if let threadID { fields["threadId"] = threadID }
    fields.merge(extra) { _, new in new }
    return try! JSONSerialization.data(withJSONObject: fields)
}

struct ProtocolTests {
    @Test func decodesValidDeliveries() throws {
        let request = try GatewayProtocol.decodeDeliveryRequest(deliveryBody())
        #expect(request.idempotencyId == "gid-1")
        #expect(request.taskRef == ResourceReference(namespace: "orka", name: "task-1"))
        _ = try GatewayProtocol.decodeDeliveryRequest(deliveryBody(kind: "message", text: String(repeating: "a", count: 16 << 10)))
        _ = try GatewayProtocol.decodeDeliveryRequest(deliveryBody(text: String(repeating: "a", count: 64 << 10)))
        _ = try GatewayProtocol.decodeDeliveryRequest(deliveryBody(text: "line one\nline two\r\n\tend"))
    }

    @Test func rejectsInvalidDeliveries() {
        let invalid: [Data] = [
            Data(),
            Data("not json".utf8),
            Data("[]".utf8),
            deliveryBody() + Data("{}".utf8),
            deliveryBody(extra: ["unexpected": true]),
            deliveryBody(extra: ["taskRef": ["namespace": "orka", "name": "task-1", "uid": "x"]]),
            deliveryBody(extra: ["protocolVersion": "orka.gateway.v2"]),
            deliveryBody(extra: ["text": 5]),
            deliveryBody(kind: "typing"),
            deliveryBody(kind: "message", text: String(repeating: "a", count: (16 << 10) + 1)),
            deliveryBody(text: String(repeating: "a", count: (64 << 10) + 1)),
            deliveryBody(text: ""),
            deliveryBody(text: "bell\u{07}"),
            deliveryBody(deliveryID: ""),
            deliveryBody(idempotencyID: " padded"),
            deliveryBody(contextID: String(repeating: "c", count: 257)),
            deliveryBody(threadID: "line\nbreak"),
        ]
        for body in invalid {
            #expect(throws: ProtocolError.self) { try GatewayProtocol.decodeDeliveryRequest(body) }
        }
    }

    @Test func validatesEventsAndIngressResponses() throws {
        var event = EventEnvelope(
            externalEventId: "MSG-1", accountId: "mac-messages", contextId: testChat,
            sender: EventSender(id: testHandle), text: "hi", replyTarget: testChat, occurredAt: Date()
        )
        try GatewayProtocol.validate(event)
        event.text = String(repeating: "a", count: (64 << 10) + 1)
        #expect(throws: ProtocolError.self) { try GatewayProtocol.validate(event) }

        try GatewayProtocol.validate(IngressResponse(status: "accepted", eventId: "gev-1", state: "Queued"))
        #expect(throws: ProtocolError.self) {
            try GatewayProtocol.validate(IngressResponse(status: "maybe", eventId: "gev-1", state: "Queued"))
        }
        #expect(throws: ProtocolError.self) {
            try GatewayProtocol.validate(IngressResponse(status: "accepted", eventId: "", state: "Queued"))
        }
    }

    @Test func comparesBearerTokens() {
        #expect(GatewayProtocol.bearerToken("Bearer abc") == "abc")
        #expect(GatewayProtocol.bearerToken("bearer abc") == "abc")
        #expect(GatewayProtocol.bearerToken("Basic abc") == nil)
        #expect(GatewayProtocol.bearerToken("Bearer a b") == nil)
        #expect(GatewayProtocol.constantTimeEqual("abc", "abc"))
        #expect(!GatewayProtocol.constantTimeEqual("abd", "abc"))
        #expect(!GatewayProtocol.constantTimeEqual("ab", "abc"))
        #expect(!GatewayProtocol.constantTimeEqual("", ""))
        #expect(!GatewayProtocol.constantTimeEqual(nil, "abc"))
    }

    @Test func sanitizesMessages() {
        #expect(GatewayProtocol.sanitizeMessage("  bad\u{07} input\n ", limit: 0) == "bad input")
        #expect(GatewayProtocol.sanitizeMessage("héllo", limit: 2) == "h")
    }
}
