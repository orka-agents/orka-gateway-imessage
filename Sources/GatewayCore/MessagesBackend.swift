import Foundation

/// One Messages row as the gateway sees it.
public struct IncomingMessage: Sendable, Equatable {
    public var rowID: Int64
    public var guid: String
    public var chatGUID: String
    /// The sender's handle; empty for rows sent by this account.
    public var sender: String
    public var text: String
    public var createdAt: Date?
    public var isFromMe: Bool
    public var isReaction: Bool
    public var isPoll: Bool
    /// An edit or unsend snapshot of an earlier row rather than a new row.
    public var isMutation: Bool

    public init(
        rowID: Int64,
        guid: String,
        chatGUID: String,
        sender: String,
        text: String,
        createdAt: Date?,
        isFromMe: Bool = false,
        isReaction: Bool = false,
        isPoll: Bool = false,
        isMutation: Bool = false
    ) {
        self.rowID = rowID
        self.guid = guid
        self.chatGUID = chatGUID
        self.sender = sender
        self.text = text
        self.createdAt = createdAt
        self.isFromMe = isFromMe
        self.isReaction = isReaction
        self.isPoll = isPoll
        self.isMutation = isMutation
    }
}

/// The outcome of one send, classified by what Messages can prove.
public enum SendOutcome: Sendable, Equatable {
    /// Messages recorded the sent row.
    case delivered(providerMessageID: String?)
    /// The send provably never started, so retrying is safe.
    case notDispatched(String)
    /// The request can never succeed.
    case rejected(String)
    /// The send may have happened. It must never be retried.
    case unknown(String)
}

/// A live watch over new Messages rows. It is consumed by one task.
public final class MessageSubscription: @unchecked Sendable {
    private let nextMessage: () async throws -> IncomingMessage?

    public init(next: @escaping () async throws -> IncomingMessage?) {
        nextMessage = next
    }

    /// Returns the next row, or nil when the watch ended without an error.
    public func next() async throws -> IncomingMessage? {
        try await nextMessage()
    }
}

/// The Messages access the gateway needs.
public protocol MessagesBackend: Sendable {
    /// Returns the newest message row, or 0 when there is none.
    func latestRowID() async throws -> Int64
    /// Watches every chat for rows after rowID; -1 starts from the first row.
    func watch(after rowID: Int64) async throws -> MessageSubscription
    /// Sends text to one chat. Sends are never retried by the backend.
    func send(text: String, toChat chatGUID: String) async -> SendOutcome
}
