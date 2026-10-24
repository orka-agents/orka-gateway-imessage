import Foundation

public enum IngressError: Error, Equatable, CustomStringConvertible {
    /// Orka rejected the event itself; resending it cannot succeed.
    case permanent(status: Int)
    /// Orka could not be reached or did not admit the event yet.
    case transient(String)

    public var description: String {
        switch self {
        case let .permanent(status): "Orka ingress returned HTTP \(status)"
        case let .transient(message): message
        }
    }
}

/// Orka's durable admission of one event.
public struct IngressAdmission: Sendable, Equatable {
    /// The ingress status, or "unrecognized" for an acknowledgement this
    /// gateway cannot validate.
    public var status: String
    public var eventID: String
}

/// Posts gateway events to Orka.
public protocol EventIngress: Sendable {
    func admit(_ event: EventEnvelope) async throws -> IngressAdmission
}

/// Posts events to Orka over HTTP without proxies, cookies, or redirects.
public final class HTTPEventIngress: EventIngress {
    private let url: URL
    private let token: String
    private let session: URLSession

    public init(url: URL, token: String, timeout: TimeInterval = 15, protocolClasses: [AnyClass]? = nil) {
        self.url = url
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func admit(_ event: EventEnvelope) async throws -> IngressAdmission {
        guard let body = try? JSONEncoder.gateway().encode(event) else {
            throw IngressError.permanent(status: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw IngressError.transient("Orka ingress request failed")
        }
        guard let http = response as? HTTPURLResponse, data.count <= GatewayProtocol.maxAdapterResponseBytes else {
            throw IngressError.transient("Orka ingress response was invalid")
        }
        switch http.statusCode {
        case 202:
            break
        case 400, 413, 422:
            throw IngressError.permanent(status: http.statusCode)
        default:
            throw IngressError.transient("Orka ingress returned HTTP \(http.statusCode)")
        }
        // HTTP 202 is Orka's durable admission. An acknowledgement body this
        // gateway cannot validate must not cause a resend loop.
        guard let ingress = try? JSONDecoder().decode(IngressResponse.self, from: data),
              (try? GatewayProtocol.validate(ingress)) != nil
        else {
            return IngressAdmission(status: "unrecognized", eventID: "")
        }
        return IngressAdmission(status: ingress.status, eventID: ingress.eventId)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
