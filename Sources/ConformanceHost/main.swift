// A headless gateway host for Orka's conformance tool. Its Messages backend is
// a fake that records sends to FAKE_SENDS; it never touches Messages.

import Foundation
import GatewayCore
import Logging

/// Records each send as one JSON line and reports it delivered.
final class FakeMessagesBackend: MessagesBackend {
    private let sendsPath: String

    init(sendsPath: String) {
        self.sendsPath = sendsPath
    }

    func latestRowID() async throws -> Int64 { 0 }

    func watch(after _: Int64) async throws -> MessageSubscription {
        MessageSubscription {
            // No Messages rows ever arrive; wait until cancelled.
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
            return nil
        }
    }

    func send(text _: String, toChat chatGUID: String) async -> SendOutcome {
        let line = (try? JSONSerialization.data(withJSONObject: ["chat_guid": chatGUID])) ?? Data()
        guard let handle = FileHandle(forWritingAtPath: sendsPath) else {
            return .notDispatched("FAKE_SENDS is not writable")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: line + Data("\n".utf8))
        } catch {
            return .unknown("FAKE_SENDS write failed")
        }
        return .delivered(providerMessageID: UUID().uuidString)
    }
}

func environment(_ name: String, default fallback: String = "") -> String {
    let value = ProcessInfo.processInfo.environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return value.isEmpty ? fallback : value
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("gateway-conformance-host: \(message)\n".utf8))
    exit(2)
}

LoggingSystem.bootstrap { label in
    var handler = StreamLogHandler.standardError(label: label)
    handler.logLevel = Logger.Level(rawValue: environment("LOG_LEVEL", default: "info")) ?? .info
    return handler
}

let listen = environment("LISTEN_ADDRESS", default: "127.0.0.1:8787")
guard let separator = listen.lastIndex(of: ":"), let port = Int(listen[listen.index(after: separator)...]) else {
    fail("LISTEN_ADDRESS must be host:port")
}
let sends = environment("FAKE_SENDS")
if sends.isEmpty { fail("FAKE_SENDS is required") }

let configuration: GatewayConfiguration
let store: GatewayStore
do {
    configuration = try GatewayConfiguration(
        accountID: environment("IMESSAGE_ACCOUNT_ID"),
        allowedSenders: environment("IMESSAGE_ALLOWED_SENDERS"),
        conformanceChatGUID: environment("IMESSAGE_CONFORMANCE_CHAT_GUID"),
        ingressURL: environment("ORKA_GATEWAY_INGRESS_URL"),
        inboundToken: environment("ORKA_GATEWAY_INBOUND_TOKEN"),
        outboundToken: environment("ORKA_GATEWAY_OUTBOUND_TOKEN"),
        listenHost: String(listen[..<separator]),
        listenPort: port
    )
    store = try GatewayStore(path: environment("DATABASE_PATH"))
} catch {
    fail("\(error)")
}

let runtime = GatewayRuntime(
    configuration: configuration,
    store: store,
    backend: FakeMessagesBackend(sendsPath: sends),
    logger: Logger(label: "gateway")
)
let task = Task { try await runtime.run() }
var signalSources: [DispatchSourceSignal] = []
for signalNumber in [SIGTERM, SIGINT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
    source.setEventHandler { task.cancel() }
    source.resume()
    signalSources.append(source)
}
do {
    try await task.value
} catch is CancellationError {
} catch {
    fail("\(error)")
}
