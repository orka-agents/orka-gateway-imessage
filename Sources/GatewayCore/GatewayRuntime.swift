import Foundation
import Hummingbird
import Logging

/// Runs the adapter's HTTP server and inbound forwarding together.
public struct GatewayRuntime: Sendable {
    private let configuration: GatewayConfiguration
    private let store: GatewayStore
    private let backend: any MessagesBackend
    private let ingress: any EventIngress
    private let logger: Logger
    private let observer: GatewayObserver

    public init(
        configuration: GatewayConfiguration,
        store: GatewayStore,
        backend: any MessagesBackend,
        ingress: (any EventIngress)? = nil,
        logger: Logger,
        observer: @escaping GatewayObserver = { _ in }
    ) {
        self.configuration = configuration
        self.store = store
        self.backend = backend
        self.ingress = ingress ?? HTTPEventIngress(url: configuration.ingressURL, token: configuration.inboundToken)
        self.logger = logger
        self.observer = observer
    }

    /// Serves and forwards until the task is cancelled or the server fails.
    public func run() async throws {
        let deliveries = DeliveryService(
            configuration: configuration, store: store, backend: backend, logger: logger, observer: observer
        )
        let forwarder = InboundForwarder(
            configuration: configuration, store: store, backend: backend, ingress: ingress, logger: logger,
            observer: observer
        )
        let router = GatewayServer.router(configuration: configuration, store: store, deliveries: deliveries)
        let host = configuration.listenHost
        let port = configuration.listenPort
        let observer = observer
        let logger = logger
        let application = Application(
            router: router,
            configuration: .init(address: .hostname(host, port: port), serverName: nil),
            onServerRunning: { _ in
                logger.info("starting iMessage gateway", metadata: [
                    "address": "\(host):\(port)", "allowlisted_handles": "\(configuration.allowlist.count)",
                ])
                observer(.listening(host: host, port: port))
            },
            logger: logger
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await application.run() }
            group.addTask { await forwarder.run() }
            // The forwarder only returns on cancellation; the server returns or
            // throws when it stops. Either way, stop the other.
            _ = try await group.next()
            group.cancelAll()
        }
    }
}
