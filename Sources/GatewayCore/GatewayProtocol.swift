import Foundation

/// Orka's provider-neutral `orka.gateway.v1` contract.
public enum GatewayProtocol {
    public static let version = "orka.gateway.v1"
    public static let eventTypeText = "text"

    public static let maxHTTPBodyBytes = 256 << 10
    public static let maxTextBytes = 64 << 10
    public static let maxInterimTextBytes = 16 << 10
    public static let maxIdentityBytes = 256
    public static let maxAdapterResponseBytes = 64 << 10
}

public enum DeliveryKind: String, Codable, Sendable {
    case final
    case error
    case message
}

public enum DeliveryStatus: String, Codable, Sendable {
    case delivered
    case retryableError
    case nonRetryableError
}

public enum IngressStatus: String, Codable, Sendable {
    case accepted
    case duplicate
    case rejected
    case deadLettered
}

public struct EventSender: Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

public struct EventEnvelope: Codable, Sendable, Equatable {
    public var protocolVersion: String
    public var externalEventId: String
    public var eventType: String
    public var accountId: String
    public var contextId: String
    public var threadId: String?
    public var sender: EventSender
    public var text: String
    public var replyTarget: String?
    public var occurredAt: Date?
    public var receivedAt: Date?

    public init(
        externalEventId: String,
        accountId: String,
        contextId: String,
        sender: EventSender,
        text: String,
        replyTarget: String?,
        occurredAt: Date?
    ) {
        protocolVersion = GatewayProtocol.version
        self.externalEventId = externalEventId
        eventType = GatewayProtocol.eventTypeText
        self.accountId = accountId
        self.contextId = contextId
        self.sender = sender
        self.text = text
        self.replyTarget = replyTarget
        self.occurredAt = occurredAt
    }
}

public struct IngressResponse: Codable, Sendable, Equatable {
    public var status: String
    public var eventId: String
    public var state: String
    public var message: String?

    public init(status: String, eventId: String, state: String, message: String? = nil) {
        self.status = status
        self.eventId = eventId
        self.state = state
        self.message = message
    }
}

public struct Capabilities: Codable, Sendable, Equatable {
    public var inboundText = true
    public var outboundText = true
    public var senderIdentity = true
    public var idempotentDelivery = true
    public var interimDelivery = true
}

public struct CapabilitiesResponse: Codable, Sendable, Equatable {
    public var protocolVersion: String
    public var adapterName: String
    public var adapterVersion: String
    public var capabilities: Capabilities
}

public struct HealthResponse: Codable, Sendable, Equatable {
    public var status: String
}

public struct ResourceReference: Codable, Sendable, Equatable {
    public var namespace: String
    public var name: String
}

public struct DeliveryRequest: Codable, Sendable, Equatable {
    public var protocolVersion: String
    public var deliveryId: String
    public var idempotencyId: String
    public var originatingEventId: String
    public var taskRef: ResourceReference?
    public var sessionRef: ResourceReference?
    public var kind: String
    public var accountId: String
    public var contextId: String
    public var threadId: String?
    public var replyTarget: String
    public var text: String
    public var metadata: [String: String]?

    public init(
        deliveryId: String,
        idempotencyId: String,
        originatingEventId: String,
        kind: String,
        accountId: String,
        contextId: String,
        replyTarget: String,
        text: String
    ) {
        protocolVersion = GatewayProtocol.version
        self.deliveryId = deliveryId
        self.idempotencyId = idempotencyId
        self.originatingEventId = originatingEventId
        self.kind = kind
        self.accountId = accountId
        self.contextId = contextId
        self.replyTarget = replyTarget
        self.text = text
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decodeIfPresent(String.self, forKey: .protocolVersion) ?? ""
        deliveryId = try container.decodeIfPresent(String.self, forKey: .deliveryId) ?? ""
        idempotencyId = try container.decodeIfPresent(String.self, forKey: .idempotencyId) ?? ""
        originatingEventId = try container.decodeIfPresent(String.self, forKey: .originatingEventId) ?? ""
        taskRef = try container.decodeIfPresent(ResourceReference.self, forKey: .taskRef)
        sessionRef = try container.decodeIfPresent(ResourceReference.self, forKey: .sessionRef)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? ""
        accountId = try container.decodeIfPresent(String.self, forKey: .accountId) ?? ""
        contextId = try container.decodeIfPresent(String.self, forKey: .contextId) ?? ""
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        replyTarget = try container.decodeIfPresent(String.self, forKey: .replyTarget) ?? ""
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata)
    }
}

public struct DeliveryResponse: Codable, Sendable, Equatable {
    public var status: DeliveryStatus
    public var providerMessageId: String?
    public var message: String?

    public static func delivered(_ providerMessageID: String?) -> DeliveryResponse {
        DeliveryResponse(status: .delivered, providerMessageId: providerMessageID.flatMap { $0.isEmpty ? nil : $0 })
    }

    public static func rejected(_ message: String) -> DeliveryResponse {
        DeliveryResponse(status: .nonRetryableError, message: message)
    }

    public static func retryable(_ message: String) -> DeliveryResponse {
        DeliveryResponse(status: .retryableError, message: message)
    }
}

public struct ProtocolError: Error, Equatable, CustomStringConvertible {
    public let description: String

    init(_ description: String) {
        self.description = description
    }
}

// MARK: - Validation

extension GatewayProtocol {
    private static let deliveryKeys: Set<String> = [
        "protocolVersion", "deliveryId", "idempotencyId", "originatingEventId", "taskRef", "sessionRef",
        "kind", "accountId", "contextId", "threadId", "replyTarget", "text", "metadata",
    ]
    private static let referenceKeys: Set<String> = ["namespace", "name"]

    /// Strictly decodes and validates one delivery request: exactly one JSON
    /// object with no unknown fields.
    public static func decodeDeliveryRequest(_ body: Data) throws -> DeliveryRequest {
        guard !body.isEmpty, body.count <= maxHTTPBodyBytes else {
            throw ProtocolError("invalid delivery request size")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: body)
        } catch {
            throw ProtocolError("invalid delivery request")
        }
        guard let fields = object as? [String: Any], Set(fields.keys).isSubset(of: deliveryKeys) else {
            throw ProtocolError("invalid delivery request")
        }
        for key in ["taskRef", "sessionRef"] {
            if let reference = fields[key] as? [String: Any], !Set(reference.keys).isSubset(of: referenceKeys) {
                throw ProtocolError("invalid delivery request")
            }
        }
        let request: DeliveryRequest
        do {
            request = try JSONDecoder().decode(DeliveryRequest.self, from: body)
        } catch {
            throw ProtocolError("invalid delivery request")
        }
        try validate(request)
        return request
    }

    /// Enforces the V1 identity and text bounds, including the smaller
    /// interim-message bound.
    public static func validate(_ request: DeliveryRequest) throws {
        guard request.protocolVersion == version else {
            throw ProtocolError("unsupported protocolVersion")
        }
        for (name, value) in [
            ("deliveryId", request.deliveryId), ("idempotencyId", request.idempotencyId),
            ("originatingEventId", request.originatingEventId), ("accountId", request.accountId),
            ("contextId", request.contextId), ("replyTarget", request.replyTarget),
        ] {
            try validateRequiredIdentity(name, value)
        }
        try validateOptionalIdentity("threadId", request.threadId ?? "")
        let limit: Int
        switch DeliveryKind(rawValue: request.kind) {
        case .message:
            limit = maxInterimTextBytes
        case .final, .error:
            limit = maxTextBytes
        case nil:
            throw ProtocolError("unsupported delivery kind")
        }
        if request.text.isEmpty || request.text.utf8.count > limit || containsUnsafeControl(request.text, allowNewlines: true) {
            throw ProtocolError("delivery text is invalid")
        }
    }

    /// Applies Orka's V1 event checks before ingress so a malformed mapping
    /// fails locally instead of being retried against Orka.
    public static func validate(_ event: EventEnvelope) throws {
        guard event.protocolVersion == version, event.eventType == eventTypeText else {
            throw ProtocolError("unsupported event version or type")
        }
        for (name, value) in [
            ("externalEventId", event.externalEventId), ("accountId", event.accountId),
            ("contextId", event.contextId), ("sender.id", event.sender.id),
        ] {
            try validateRequiredIdentity(name, value)
        }
        for (name, value) in [
            ("threadId", event.threadId), ("sender.displayName", event.sender.displayName),
            ("replyTarget", event.replyTarget),
        ] {
            try validateOptionalIdentity(name, value ?? "")
        }
        if event.text.isEmpty || event.text.utf8.count > maxTextBytes || containsUnsafeControl(event.text, allowNewlines: true) {
            throw ProtocolError("event text is invalid")
        }
    }

    /// Checks Orka's durable admission acknowledgement.
    public static func validate(_ response: IngressResponse) throws {
        guard IngressStatus(rawValue: response.status) != nil else {
            throw ProtocolError("unsupported ingress status")
        }
        try validateRequiredIdentity("eventId", response.eventId)
        if response.state.isEmpty || response.state.utf8.count > 64 || containsUnsafeControl(response.state, allowNewlines: false) {
            throw ProtocolError("ingress state is invalid")
        }
        let message = response.message ?? ""
        if message.utf8.count > 1024 || containsUnsafeControl(message, allowNewlines: true) {
            throw ProtocolError("ingress message is invalid")
        }
    }

    /// Reports whether value is a safe non-empty V1 identity.
    public static func isValidIdentity(_ value: String) -> Bool {
        (try? validateRequiredIdentity("identity", value)) != nil
    }

    /// Returns the token from an `Authorization: Bearer <token>` header.
    public static func bearerToken(_ header: String?) -> String? {
        guard let header else { return nil }
        let parts = header.split(whereSeparator: \.isWhitespace)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1])
    }

    /// Compares bearer tokens in time independent of where they differ.
    public static func constantTimeEqual(_ got: String?, _ want: String) -> Bool {
        let got = Array((got ?? "").trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let want = Array(want.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard !got.isEmpty, !want.isEmpty, got.count == want.count else { return false }
        var difference: UInt8 = 0
        for index in got.indices {
            difference |= got[index] ^ want[index]
        }
        return difference == 0
    }

    /// Strips controls and bounds adapter-owned messages.
    public static func sanitizeMessage(_ message: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in message.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
            where !isControl(scalar) || scalar == "\n" || scalar == "\t"
        {
            scalars.append(scalar)
        }
        return truncate(String(scalars), toBytes: limit)
    }

    static func truncate(_ value: String, toBytes limit: Int) -> String {
        guard limit > 0, value.utf8.count > limit else { return value }
        var result = String.UnicodeScalarView()
        var used = 0
        for scalar in value.unicodeScalars {
            let size = String(scalar).utf8.count
            if used + size > limit { break }
            used += size
            result.append(scalar)
        }
        return String(result)
    }

    static func validateRequiredIdentity(_ name: String, _ value: String) throws {
        if value.isEmpty {
            throw ProtocolError("\(name) is required")
        }
        try validateOptionalIdentity(name, value)
    }

    static func validateOptionalIdentity(_ name: String, _ value: String) throws {
        if value.isEmpty { return }
        if value != value.trimmingCharacters(in: .whitespacesAndNewlines) || value.utf8.count > maxIdentityBytes
            || containsUnsafeControl(value, allowNewlines: false)
        {
            throw ProtocolError("\(name) is invalid")
        }
    }

    static func containsUnsafeControl(_ value: String, allowNewlines: Bool) -> Bool {
        value.unicodeScalars.contains { scalar in
            guard isControl(scalar) else { return false }
            return !(allowNewlines && (scalar == "\n" || scalar == "\r" || scalar == "\t"))
        }
    }

    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control
    }
}

extension JSONEncoder {
    /// Encodes protocol payloads with RFC 3339 timestamps.
    static func gateway() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(rfc3339(date))
        }
        return encoder
    }
}

func rfc3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}
