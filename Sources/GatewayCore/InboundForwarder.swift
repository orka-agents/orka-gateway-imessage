import Foundation
import Logging

/// Watches Messages and forwards allowlisted text to Orka. It resumes from
/// the durable cursor after every interruption, so a message is never
/// skipped; Orka deduplicates replays by message GUID.
public final class InboundForwarder: Sendable {
    /// How close in time an outbound send and an identical inbound row in the
    /// same chat must be for the row to count as the send's echo.
    static let echoWindow: TimeInterval = 120
    /// Matches Orka's event expiry. Older rows are never forwarded, which also
    /// bounds any replay after a cursor reset.
    static let maxMessageAge: TimeInterval = 24 * 60 * 60
    static let stableWatchRun: TimeInterval = 60

    private let configuration: GatewayConfiguration
    private let store: GatewayStore
    private let backend: any MessagesBackend
    private let ingress: any EventIngress
    private let logger: Logger
    private let observer: GatewayObserver
    private let maxBackoff: TimeInterval
    private let now: @Sendable () -> Date

    public init(
        configuration: GatewayConfiguration,
        store: GatewayStore,
        backend: any MessagesBackend,
        ingress: any EventIngress,
        logger: Logger,
        observer: @escaping GatewayObserver,
        maxBackoff: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.configuration = configuration
        self.store = store
        self.backend = backend
        self.ingress = ingress
        self.logger = logger
        self.observer = observer
        self.maxBackoff = maxBackoff
        self.now = now
    }

    /// Runs until the task is cancelled.
    public func run() async {
        var backoff: TimeInterval = 0
        while !Task.isCancelled {
            let started = now()
            let message: String
            do {
                try await watchOnce()
                message = "watch ended"
            } catch {
                message = GatewayProtocol.sanitizeMessage("\(error)", limit: 512)
            }
            if Task.isCancelled { return }
            if now().timeIntervalSince(started) > Self.stableWatchRun {
                backoff = 0
            }
            backoff = nextBackoff(backoff)
            logger.warning("iMessage watch ended; resubscribing", metadata: [
                "error": "\(message)", "retry_in": "\(Int(backoff))s",
            ])
            observer(.watchEnded(message))
            guard await sleep(backoff) else { return }
        }
    }

    func watchOnce() async throws {
        var (cursor, initialized) = try await store.cursor()
        if !initialized {
            // First start: begin after the newest existing row and persist
            // that position, so history is never forwarded and a restart
            // resumes here.
            try await store.initializeCursor(try await backend.latestRowID())
            cursor = try await store.cursor().rowID
        }
        // Cursor 0 means the database had no rows when it was initialized.
        let subscription = try await backend.watch(after: cursor == 0 ? -1 : cursor)
        logger.info("watching iMessage", metadata: ["since_rowid": "\(cursor)"])
        observer(.watching(sinceRowID: cursor))
        while let message = try await subscription.next() {
            try await handle(message)
            if Task.isCancelled { return }
        }
    }

    /// Forwards or skips one row and then advances the cursor. It throws only
    /// when the cursor must not advance.
    func handle(_ message: IncomingMessage) async throws {
        // Edits and unsends reuse an earlier row and never advance the cursor.
        if message.isMutation || message.rowID <= 0 { return }
        let event: EventEnvelope
        switch try await map(message) {
        case let .skip(reason):
            logger.debug("skipping iMessage", metadata: ["rowid": "\(message.rowID)", "reason": "\(reason)"])
            observer(.skipped(rowID: message.rowID, reason: reason))
            try await store.advanceCursor(message.rowID)
            return
        case let .forward(mapped):
            event = mapped
        }
        // Record the chat before Orka can reply to it.
        try await store.rememberReplyChat(event.contextId)
        var backoff: TimeInterval = 0
        while true {
            do {
                let admission = try await ingress.admit(event)
                logger.info("forwarded iMessage to Orka", metadata: [
                    "rowid": "\(message.rowID)", "event_id": "\(admission.eventID)", "status": "\(admission.status)",
                ])
                observer(.forwarded(rowID: message.rowID, chatGUID: event.contextId, status: admission.status))
                break
            } catch let IngressError.permanent(status) {
                logger.error("Orka rejected iMessage event; skipping it", metadata: [
                    "rowid": "\(message.rowID)", "status": "\(status)",
                ])
                observer(.ingressRejected(rowID: message.rowID, "Orka ingress returned HTTP \(status)"))
                break
            } catch {
                backoff = nextBackoff(backoff)
                let detail = GatewayProtocol.sanitizeMessage("\(error)", limit: 512)
                logger.warning("Orka ingress unavailable; retrying", metadata: [
                    "rowid": "\(message.rowID)", "error": "\(detail)", "retry_in": "\(Int(backoff))s",
                ])
                observer(.ingressRetrying(rowID: message.rowID, detail))
                guard await sleep(backoff) else { throw CancellationError() }
            }
        }
        try await store.advanceCursor(message.rowID)
    }

    enum Mapping: Equatable {
        case forward(EventEnvelope)
        case skip(String)
    }

    /// Converts a Messages row into an Orka event, or returns a skip reason.
    /// Only text from allowlisted senders in allowed chats is forwarded.
    func map(_ message: IncomingMessage) async throws -> Mapping {
        if message.isFromMe {
            try await recordOutgoing(message)
            return .skip("sent by this account")
        }
        if message.isReaction { return .skip("reaction") }
        if message.isPoll { return .skip("poll") }
        guard let chat = try? ChatGUID(parsing: message.chatGUID) else { return .skip("unsupported chat") }
        if chat.isGroup { return .skip("group chat") }
        guard configuration.allowlist.contains(chat.identifier) else { return .skip("chat is not allowlisted") }
        guard let sender = try? Handles.normalize(message.sender), configuration.allowlist.contains(sender) else {
            return .skip("sender is not allowlisted")
        }
        let text = Self.cleanText(message.text)
        if text.isEmpty { return .skip("no text") }
        if text.utf8.count > GatewayProtocol.maxTextBytes { return .skip("text is too long") }
        guard GatewayProtocol.isValidIdentity(message.guid) else { return .skip("invalid message GUID") }
        if let created = message.createdAt, now().timeIntervalSince(created) > Self.maxMessageAge {
            return .skip("older than the event expiry")
        }
        // Match echoes against the row's own time so a late-processed echo
        // still matches its send.
        let digest = Digest.text(text)
        if try await store.sentNear(chatGUID: chat.guid, textDigest: digest, at: message.createdAt ?? now(), window: Self.echoWindow) {
            return .skip("echo of a gateway send")
        }
        if let created = message.createdAt,
           try await store.hasOutgoingRow(chatGUID: chat.guid, textDigest: digest, createdAt: created)
        {
            return .skip("copy of an outgoing self-chat row")
        }
        let event = EventEnvelope(
            externalEventId: message.guid,
            accountId: configuration.accountID,
            contextId: chat.guid,
            sender: EventSender(id: sender),
            text: text,
            replyTarget: chat.guid,
            occurredAt: message.createdAt
        )
        guard (try? GatewayProtocol.validate(event)) != nil else { return .skip("invalid event") }
        return .forward(event)
    }

    /// Remembers an outgoing row in an allowlisted chat so a received copy
    /// that shares its timestamp in a self-chat is not forwarded.
    private func recordOutgoing(_ message: IncomingMessage) async throws {
        let text = Self.cleanText(message.text)
        guard let chat = try? ChatGUID(parsing: message.chatGUID), !chat.isGroup,
              configuration.allowlist.contains(chat.identifier), !text.isEmpty, let created = message.createdAt
        else { return }
        try await store.recordOutgoingRow(chatGUID: chat.guid, textDigest: Digest.text(text), createdAt: created)
    }

    /// Drops attachment placeholders and controls Orka rejects.
    static func cleanText(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where scalar != "\u{FFFC}" {
            if GatewayProtocol.isControl(scalar), scalar != "\n", scalar != "\r", scalar != "\t" { continue }
            scalars.append(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nextBackoff(_ current: TimeInterval) -> TimeInterval {
        current <= 0 ? min(1, maxBackoff) : min(current * 2, maxBackoff)
    }

    private func sleep(_ seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return true
        } catch {
            return false
        }
    }
}
