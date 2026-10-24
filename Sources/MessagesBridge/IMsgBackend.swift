import Foundation
import GatewayCore
import IMsgCore

/// Messages access through imsg's IMsgCore: reads `chat.db` and sends with
/// Messages' AppleScript interface. Reading needs Full Disk Access and
/// sending needs Automation permission for Messages, both granted to the
/// process that hosts this backend.
public final class IMsgBackend: MessagesBackend, @unchecked Sendable {
    public enum BackendError: Error, CustomStringConvertible {
        case databaseUnavailable(String)

        public var description: String {
            switch self {
            case let .databaseUnavailable(detail): "Messages database unavailable: \(detail)"
            }
        }
    }

    private static let verificationWindow: TimeInterval = 8
    private let databasePath: String
    private let lock = NSLock()
    private var cachedStore: MessageStore?
    /// Sends run one at a time on their own thread: an AppleScript send
    /// blocks until Messages answers.
    private let sendQueue = DispatchQueue(label: "ai.orka.gateway-imessage.send", qos: .userInitiated)

    public init(databasePath: String = MessageStore.defaultPath) {
        self.databasePath = databasePath
    }

    public func latestRowID() async throws -> Int64 {
        try store().maxRowID()
    }

    public func watch(after rowID: Int64) async throws -> MessageSubscription {
        let store = try store()
        // IMsgCore tails from the newest row for 0 and replays everything after
        // a negative cursor, so -1 starts from the first row.
        let stream = MessageWatcher(store: store).stream(
            sinceRowID: rowID,
            configuration: MessageWatcherConfiguration(includeReactions: false)
        )
        var iterator = stream.makeAsyncIterator()
        var chatGUIDs: [Int64: String] = [:]
        return MessageSubscription {
            guard let message = try await iterator.next() else { return nil }
            let chatGUID: String
            if let cached = chatGUIDs[message.chatID] {
                chatGUID = cached
            } else {
                chatGUID = try store.chatInfo(chatID: message.chatID)?.guid ?? ""
                chatGUIDs[message.chatID] = chatGUID
            }
            return IncomingMessage(
                rowID: message.rowID,
                guid: message.guid,
                chatGUID: chatGUID,
                sender: message.isFromMe ? "" : message.sender,
                text: message.text,
                createdAt: message.date,
                isFromMe: message.isFromMe,
                isReaction: message.isReaction,
                isPoll: message.poll != nil,
                isMutation: message.mutationEvent != nil
            )
        }
    }

    public func send(text: String, toChat chatGUID: String) async -> SendOutcome {
        await withCheckedContinuation { continuation in
            sendQueue.async {
                continuation.resume(returning: self.sendNow(text: text, chatGUID: chatGUID))
            }
        }
    }

    private func sendNow(text: String, chatGUID: String) -> SendOutcome {
        let store: MessageStore
        let chat: ChatInfo
        let target: DirectParticipantTarget
        do {
            store = try self.store()
            guard let found = try store.chatInfo(matchingExactGUID: chatGUID) else {
                return .rejected("chat not found in Messages")
            }
            // Never send to a chat Messages does not record as a one-to-one
            // conversation, whatever its GUID says.
            guard let direct = DirectParticipantTarget(chat: found, participants: try store.participants(chatID: found.id)) else {
                return .rejected("chat is not a direct conversation")
            }
            chat = found
            target = direct
        } catch {
            return .notDispatched("Messages database unavailable")
        }

        let options = MessageSendOptions(
            recipient: "",
            text: text,
            chatGUID: chatGUID,
            allowSMSFallback: false,
            directParticipantTarget: target
        )
        let sentAt = Date()
        do {
            _ = try MessageSender().sendResolvingRoute(options)
        } catch let failure as DeliveryFailure {
            return failure.retrySafe ? .notDispatched(failure.description) : .unknown(failure.description)
        } catch {
            return .unknown("Messages send failed: \(error)")
        }

        // Confirm the send by finding its outgoing row; anything less is an
        // unknown outcome, never a retry.
        let deadline = Date().addingTimeInterval(Self.verificationWindow)
        repeat {
            if let message = try? store.latestSentMessage(
                matchingText: text, chatID: chat.id, since: sentAt.addingTimeInterval(-2)
            ) {
                return .delivered(providerMessageID: message.guid)
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline
        return .unknown("Messages accepted the send, but no matching outgoing row appeared")
    }

    private func store() throws -> MessageStore {
        lock.lock()
        defer { lock.unlock() }
        if let cachedStore { return cachedStore }
        do {
            let store = try MessageStore(path: databasePath)
            cachedStore = store
            return store
        } catch {
            throw BackendError.databaseUnavailable(Self.isPermissionError(error) ? "Full Disk Access is required" : "\(error)")
        }
    }

    private static func isPermissionError(_ error: any Error) -> Bool {
        if case .permissionDenied = error as? IMsgError { return true }
        return false
    }
}
