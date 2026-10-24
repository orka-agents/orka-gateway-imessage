import Foundation
import Hummingbird
import Logging
import ServiceLifecycle

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
    /// Cancellation shuts the server down gracefully, letting in-flight
    /// requests finish for up to ten seconds.
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
        var serviceConfiguration = ServiceGroupConfiguration(services: [application], logger: logger)
        serviceConfiguration.maximumGracefulShutdownDuration = .seconds(10)
        let services = ServiceGroup(configuration: serviceConfiguration)
        // Unstructured, so cancelling run() requests a graceful shutdown
        // instead of cancelling the server outright.
        let server = Task { try await services.run() }
        let forwarding = Task { await forwarder.run() }
        try await withTaskCancellationHandler {
            let result = await server.result
            forwarding.cancel()
            await forwarding.value
            try result.get()
        } onCancel: {
            forwarding.cancel()
            Task { await services.triggerGracefulShutdown() }
        }
    }
}
