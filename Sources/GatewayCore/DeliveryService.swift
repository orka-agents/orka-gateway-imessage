import Foundation
import Logging

/// Handles Orka deliveries: authorizes the destination, sends at most once,
/// and replays the durable outcome for every retry of the same delivery.
public final class DeliveryService: Sendable {
    /// The account, context, and reply target Orka's conformance tool uses
    /// for its delivery probes.
    static let conformanceRoute = "conformance"

    private let configuration: GatewayConfiguration
    private let store: GatewayStore
    private let backend: any MessagesBackend
    private let logger: Logger
    private let observer: GatewayObserver
    /// Serializes sends so a sending record always means a send is in flight
    /// in this process.
    private let gate = AsyncGate()

    public init(
        configuration: GatewayConfiguration,
        store: GatewayStore,
        backend: any MessagesBackend,
        logger: Logger,
        observer: @escaping GatewayObserver
    ) {
        self.configuration = configuration
        self.store = store
        self.backend = backend
        self.logger = logger
        self.observer = observer
    }

    /// Handles one delivery request body; nil means it exceeded the size limit.
    public func handle(body: Data?) async -> (status: Int, response: DeliveryResponse) {
        guard let body else {
            return (413, .rejected("invalid request body"))
        }
        guard let request = try? GatewayProtocol.decodeDeliveryRequest(body),
              let digest = try? Self.digest(request)
        else {
            return (400, .rejected("invalid delivery"))
        }
        do {
            if let record = try await store.delivery(request.idempotencyId) {
                if record.requestDigest != digest {
                    return (200, .rejected("delivery identity conflict"))
                }
                if record.state.isTerminal {
                    return (200, Self.replay(record))
                }
            }
        } catch {
            return (200, .retryable("delivery store unavailable"))
        }
        // Detach from the caller so an Orka-side timeout cannot abandon a send
        // that has already started; a retry replays the stored outcome.
        let response = await Task {
            await gate.withLock { await self.deliver(request, digest: digest) }
        }.value
        return (200, response)
    }

    private func deliver(_ request: DeliveryRequest, digest: String) async -> DeliveryResponse {
        let chatGUID: String
        do {
            chatGUID = try await deliveryChat(request)
        } catch let error as RouteError {
            logger.warning("rejected iMessage delivery route", metadata: [
                "delivery_id": "\(request.deliveryId)", "reason": "\(error.reason)",
            ])
            observer(.deliveryRejected(error.reason))
            return .rejected(error.reason)
        } catch {
            return .retryable("delivery store unavailable")
        }
        let claim: (record: DeliveryRecord, shouldSend: Bool)
        do {
            claim = try await store.claimDelivery(
                idempotencyID: request.idempotencyId, requestDigest: digest, chatGUID: chatGUID,
                textDigest: Digest.text(request.text)
            )
        } catch StoreError.digestConflict {
            return .rejected("delivery identity conflict")
        } catch {
            return .retryable("delivery store unavailable")
        }
        guard claim.shouldSend else { return Self.replay(claim.record) }

        let outcome = await backend.send(text: request.text, toChat: chatGUID)
        let (state, providerID, message) = Self.classify(outcome)
        var finished: DeliveryRecord
        do {
            finished = try await store.finishDelivery(
                idempotencyID: request.idempotencyId, requestDigest: digest, state: state,
                providerMessageID: providerID, safeMessage: message
            )
        } catch {
            // Report the provider outcome truthfully. A restart marks the
            // unpersisted sending record unknown, which never resends.
            logger.error("failed to persist iMessage delivery result", metadata: [
                "delivery_id": "\(request.deliveryId)", "error": "\(GatewayProtocol.sanitizeMessage("\(error)", limit: 512))",
            ])
            finished = claim.record
            finished.state = state
            finished.providerMessageID = providerID
            finished.safeMessage = message
        }
        var metadata: Logger.Metadata = [
            "delivery_id": "\(request.deliveryId)", "kind": "\(request.kind)", "state": "\(state.rawValue)",
        ]
        if let detail = Self.detail(outcome) {
            metadata["detail"] = "\(GatewayProtocol.sanitizeMessage(detail, limit: 512))"
        }
        logger.info("processed iMessage delivery", metadata: metadata)
        observer(.delivered(kind: request.kind, state: state))
        return Self.replay(finished)
    }

    struct RouteError: Error {
        let reason: String
    }

    /// Resolves and authorizes the destination chat. Orka can only reply to a
    /// direct chat that produced an admitted inbound message and whose handle
    /// is still allowlisted.
    private func deliveryChat(_ request: DeliveryRequest) async throws -> String {
        let threadID = request.threadId ?? ""
        if request.accountId == Self.conformanceRoute, request.contextId == Self.conformanceRoute,
           request.replyTarget == Self.conformanceRoute, threadID.isEmpty
        {
            guard let chat = configuration.conformanceChatGUID else {
                throw RouteError(reason: "conformance chat is not configured")
            }
            return chat
        }
        guard request.accountId == configuration.accountID, request.contextId == request.replyTarget, threadID.isEmpty,
              let chat = try? ChatGUID(parsing: request.replyTarget)
        else {
            throw RouteError(reason: "delivery routing mismatch")
        }
        guard !chat.isGroup, configuration.allowlist.contains(chat.identifier) else {
            throw RouteError(reason: "destination is not allowlisted")
        }
        guard try await store.replyChatKnown(chat.guid) else {
            throw RouteError(reason: "destination has no admitted inbound message")
        }
        return chat.guid
    }

    /// Maps a send outcome to a durable delivery state. Only outcomes proven
    /// never dispatched are retryable.
    static func classify(_ outcome: SendOutcome) -> (DeliveryState, String, String) {
        switch outcome {
        case let .delivered(providerMessageID):
            let id = providerMessageID.flatMap { GatewayProtocol.isValidIdentity($0) ? $0 : nil } ?? ""
            return (.delivered, id, "")
        case .notDispatched:
            return (.retryable, "", "iMessage send failed before dispatch")
        case .rejected:
            return (.permanent, "", "iMessage rejected the send request")
        case .unknown:
            return (.unknown, "", "iMessage delivery outcome is unknown")
        }
    }

    private static func detail(_ outcome: SendOutcome) -> String? {
        switch outcome {
        case .delivered: nil
        case let .notDispatched(detail), let .rejected(detail), let .unknown(detail): detail
        }
    }

    static func replay(_ record: DeliveryRecord) -> DeliveryResponse {
        switch record.state {
        case .delivered:
            .delivered(record.providerMessageID)
        case .permanent, .unknown:
            .rejected(record.safeMessage.isEmpty ? "delivery could not be completed" : record.safeMessage)
        case .sending, .retryable:
            .retryable(record.safeMessage.isEmpty ? "delivery is in progress" : record.safeMessage)
        }
    }

    /// Digests a request with deliveryId replaced by idempotencyId, so Orka's
    /// redeliveries of one logical delivery share a digest.
    static func digest(_ request: DeliveryRequest) throws -> String {
        var canonical = request
        canonical.deliveryId = canonical.idempotencyId
        return Digest.sha256(try JSONEncoder.gateway().encode(canonical))
    }
}

/// A FIFO async mutex.
actor AsyncGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T: Sendable>(_ body: @Sendable () async -> T) async -> T {
        await acquire()
        let value = await body()
        release()
        return value
    }

    private func acquire() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
