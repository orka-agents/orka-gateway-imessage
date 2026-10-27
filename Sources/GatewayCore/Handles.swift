import Foundation

public struct HandleError: Error, Equatable, CustomStringConvertible {
    public let description: String
}

public enum Handles {
    /// Returns the canonical form of an iMessage/SMS handle: an E.164 phone
    /// number such as +14155551212, or a lowercase email address.
    public static func normalize(_ raw: String) throws -> String {
        let handle = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !handle.isEmpty, handle.utf8.count <= GatewayProtocol.maxIdentityBytes else {
            throw HandleError(description: "handle is empty or too long")
        }
        if handle.contains("@") {
            let lowered = handle.lowercased()
            let parts = lowered.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
            let invalidScalar = lowered.unicodeScalars.contains {
                CharacterSet.whitespacesAndNewlines.contains($0) || GatewayProtocol.isControl($0)
            }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty, !parts[1].contains("@"), !invalidScalar else {
                throw HandleError(description: "email handle is invalid")
            }
            return lowered
        }
        guard handle.hasPrefix("+") else {
            throw HandleError(description: "phone handle must be E.164, for example +14155551212")
        }
        let digits = handle.utf8.dropFirst()
        guard (7 ... 15).contains(digits.count), digits.allSatisfy({ (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0) }) else {
            throw HandleError(description: "phone handle must be E.164, for example +14155551212")
        }
        return handle
    }
}

/// An immutable, non-empty set of normalized handles. It bounds both inbound
/// forwarding and outbound sends.
public struct Allowlist: Sendable, Equatable {
    public let handles: Set<String>

    /// Parses a comma- or newline-separated handle list. An empty list is an
    /// error: the gateway never forwards or sends without an explicit allowlist.
    public init(parsing raw: String) throws {
        var handles = Set<String>()
        for entry in raw.split(whereSeparator: { $0 == "," || $0.isNewline }) {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            do {
                handles.insert(try Handles.normalize(trimmed))
            } catch let error as HandleError {
                throw HandleError(description: "allowlist entry \"\(trimmed)\": \(error.description)")
            }
        }
        guard !handles.isEmpty else {
            throw HandleError(description: "allowlist must contain at least one handle")
        }
        self.handles = handles
    }

    /// Reports whether raw normalizes to an allowlisted handle.
    public func contains(_ raw: String) -> Bool {
        guard let handle = try? Handles.normalize(raw) else { return false }
        return handles.contains(handle)
    }

    public var count: Int { handles.count }
}

/// A parsed Messages chat GUID such as `iMessage;-;+14155551212` (direct)
/// or `iMessage;+;chat123` (group).
public struct ChatGUID: Sendable, Equatable {
    public let guid: String
    public let service: String
    public let isGroup: Bool
    /// The handle of a direct chat or the group identifier.
    public let identifier: String

    /// Parses a chat GUID without consulting the Messages database.
    public init(parsing guid: String) throws {
        let invalidScalar = guid.unicodeScalars.contains {
            CharacterSet.whitespacesAndNewlines.contains($0) || GatewayProtocol.isControl($0)
        }
        guard !guid.isEmpty, guid.utf8.count <= GatewayProtocol.maxIdentityBytes, !invalidScalar else {
            throw HandleError(description: "chat GUID is invalid")
        }
        let parts = guid.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty, parts[1] == "-" || parts[1] == "+" else {
            throw HandleError(description: "chat GUID is invalid")
        }
        self.guid = guid
        service = String(parts[0])
        isGroup = parts[1] == "+"
        identifier = String(parts[2])
    }
}
