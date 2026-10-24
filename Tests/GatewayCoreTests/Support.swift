import Foundation
@testable import GatewayCore
import Logging

let testChat = "iMessage;-;+14155551212"
let testHandle = "+14155551212"
let outboundToken = "outbound-token"

func testConfiguration(conformanceChat: String? = nil) throws -> GatewayConfiguration {
    try GatewayConfiguration(
        accountID: "mac-messages",
        allowedSenders: "\(testHandle), Me@Example.com",
        conformanceChatGUID: conformanceChat,
        ingressURL: "http://127.0.0.1:8081/api/v1/gateways/orka/imessage/events",
        inboundToken: "inbound-token",
        outboundToken: outboundToken
    )
}

func temporaryStorePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("gateway-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("gateway.db").path
}

let quietLogger: Logger = {
    var logger = Logger(label: "test")
    logger.logLevel = .critical
    return logger
}()

/// A thread-safe box for test fakes.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var current: Value { withLock { $0 } }
}

struct RecordedSend: Equatable {
    let text: String
    let chat: String
}

final class FakeBackend: MessagesBackend {
    let sends = Locked<[RecordedSend]>([])
    let outcomes = Locked<[SendOutcome]>([])
    let watchCursors = Locked<[Int64]>([])
    let queued = Locked<[IncomingMessage]>([])
    let latest = Locked<Int64>(0)

    func latestRowID() async throws -> Int64 { latest.current }

    /// Delivers the queued rows after rowID, then ends the watch.
    func watch(after rowID: Int64) async throws -> MessageSubscription {
        watchCursors.withLock { $0.append(rowID) }
        let rows = Locked(queued.current.filter { $0.rowID > rowID })
        return MessageSubscription {
            rows.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        }
    }

    func send(text: String, toChat chatGUID: String) async -> SendOutcome {
        sends.withLock { $0.append(RecordedSend(text: text, chat: chatGUID)) }
        return outcomes.withLock { $0.isEmpty ? .delivered(providerMessageID: "MSG-GUID-\(UUID().uuidString)") : $0.removeFirst() }
    }
}

final class FakeIngress: EventIngress {
    let events = Locked<[EventEnvelope]>([])
    let failures = Locked<[IngressError]>([])

    func admit(_ event: EventEnvelope) async throws -> IngressAdmission {
        events.withLock { $0.append(event) }
        if let failure = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
            throw failure
        }
        return IngressAdmission(status: "accepted", eventID: "gev-\(event.externalEventId)")
    }
}

func message(
    _ rowID: Int64,
    text: String = "hello",
    chat: String = testChat,
    sender: String = testHandle,
    createdAt: Date? = Date(),
    isFromMe: Bool = false
) -> IncomingMessage {
    IncomingMessage(
        rowID: rowID, guid: "MSG-\(rowID)", chatGUID: chat, sender: isFromMe ? "" : sender, text: text,
        createdAt: createdAt, isFromMe: isFromMe
    )
}
