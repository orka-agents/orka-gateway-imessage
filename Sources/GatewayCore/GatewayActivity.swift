import Foundation

/// Status events the gateway reports to its host. They never carry message text.
public enum GatewayActivity: Sendable, Equatable {
    case listening(host: String, port: Int)
    case watching(sinceRowID: Int64)
    case watchEnded(String)
    case forwarded(rowID: Int64, chatGUID: String, status: String)
    case skipped(rowID: Int64, reason: String)
    case ingressRetrying(rowID: Int64, String)
    case ingressRejected(rowID: Int64, String)
    case delivered(kind: String, state: DeliveryState)
    case deliveryRejected(String)
}

public typealias GatewayObserver = @Sendable (GatewayActivity) -> Void
