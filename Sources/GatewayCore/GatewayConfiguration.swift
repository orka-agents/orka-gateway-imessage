import Foundation

public struct ConfigurationError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public let problems: [String]

    public var description: String { problems.joined(separator: "; ") }
    public var errorDescription: String? { description }
}

/// Validated gateway settings.
public struct GatewayConfiguration: Sendable {
    public static let adapterName = "orka-gateway-imessage"

    /// The stable Orka accountId for this Messages account.
    public let accountID: String
    /// Bounds every inbound sender and outbound chat. Only direct chats are
    /// supported: a group reply would reach every member.
    public let allowlist: Allowlist
    /// Optionally receives Orka conformance probe sends.
    public let conformanceChatGUID: String?
    public let ingressURL: URL
    /// The token the gateway sends to Orka.
    public let inboundToken: String
    /// The token Orka sends to the gateway.
    public let outboundToken: String
    public let listenHost: String
    public let listenPort: Int
    public let adapterVersion: String

    public init(
        accountID: String,
        allowedSenders: String,
        conformanceChatGUID: String? = nil,
        ingressURL: String,
        inboundToken: String,
        outboundToken: String,
        listenHost: String = "127.0.0.1",
        listenPort: Int = 8787,
        adapterVersion: String = "dev"
    ) throws {
        var problems: [String] = []
        let accountID = accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !GatewayProtocol.isValidIdentity(accountID) {
            problems.append("account ID is required and must be a valid identity")
        }
        var allowlist: Allowlist?
        do {
            allowlist = try Allowlist(parsing: allowedSenders)
        } catch let error as HandleError {
            problems.append("allowed senders: \(error.description)")
        }
        let inboundToken = inboundToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let outboundToken = outboundToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if inboundToken.isEmpty || outboundToken.isEmpty {
            problems.append("inbound and outbound Orka tokens are required")
        } else if inboundToken == outboundToken {
            problems.append("inbound and outbound Orka tokens must differ")
        }
        var url: URL?
        do {
            url = try Self.validateIngressURL(ingressURL)
        } catch let error as ConfigurationError {
            problems.append(contentsOf: error.problems)
        }
        let conformance = conformanceChatGUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let conformance, !conformance.isEmpty {
            let chat = try? ChatGUID(parsing: conformance)
            if chat == nil || chat!.isGroup || !(allowlist?.contains(chat!.identifier) ?? false) {
                problems.append("conformance chat must be a direct chat with an allowlisted handle")
            }
        }
        if listenHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(1 ... 65535).contains(listenPort) {
            problems.append("listen address is invalid")
        }
        guard problems.isEmpty, let allowlist, let url else {
            throw ConfigurationError(problems: problems)
        }
        self.accountID = accountID
        self.allowlist = allowlist
        self.conformanceChatGUID = (conformance?.isEmpty ?? true) ? nil : conformance
        self.ingressURL = url
        self.inboundToken = inboundToken
        self.outboundToken = outboundToken
        self.listenHost = listenHost
        self.listenPort = listenPort
        self.adapterVersion = adapterVersion.isEmpty ? "dev" : adapterVersion
    }

    /// Validates Orka's per-gateway event endpoint. Plaintext HTTP is allowed
    /// only for loopback, such as a `kubectl port-forward`.
    public static func validateIngressURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty, let url = components.url
        else {
            throw ConfigurationError(problems: ["Orka ingress URL must be absolute"])
        }
        guard scheme == "http" || scheme == "https" else {
            throw ConfigurationError(problems: ["Orka ingress URL must use http or https"])
        }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else {
            throw ConfigurationError(problems: ["Orka ingress URL must not contain credentials, query, or fragment"])
        }
        let parts = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .map(String.init)
        let path = parts.last == "" ? Array(parts.dropLast()) : parts
        guard path.count == 6, path[0] == "api", path[1] == "v1", path[2] == "gateways", !path[3].isEmpty,
              !path[4].isEmpty, path[5] == "events"
        else {
            throw ConfigurationError(problems: ["Orka ingress URL path must be /api/v1/gateways/<namespace>/<name>/events"])
        }
        if scheme == "http", !isLoopbackHost(host) {
            throw ConfigurationError(problems: ["plaintext Orka ingress is allowed only for loopback, such as a kubectl port-forward"])
        }
        return url
    }

    static func isLoopbackHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, let first = UInt8(octets[0]) else { return false }
        return first == 127 && octets.dropFirst().allSatisfy { UInt8($0) != nil }
    }
}
