import Foundation
import Hummingbird
import Logging

/// Builds the adapter's HTTP routes: unauthenticated `/healthz` and
/// `/readyz`, and the protocol routes that require Orka's outbound token.
public enum GatewayServer {
    public static func router(
        configuration: GatewayConfiguration,
        store: GatewayStore,
        deliveries: DeliveryService
    ) -> Router<BasicRequestContext> {
        let router = Router()
        router.add(middleware: SecurityHeaders())
        router.get("/healthz") { _, _ in
            json(.ok, HealthResponse(status: "ok"))
        }
        router.get("/readyz") { _, _ in
            do {
                try await store.ping()
                return json(.ok, HealthResponse(status: "ok"))
            } catch {
                return json(.serviceUnavailable, HealthResponse(status: "unavailable"))
            }
        }
        let token = configuration.outboundToken
        router.get("/v1/health") { request, _ in
            guard authorized(request, token) else { return unauthorized() }
            return json(.ok, HealthResponse(status: "ok"))
        }
        router.get("/v1/capabilities") { request, _ in
            guard authorized(request, token) else { return unauthorized() }
            return json(.ok, CapabilitiesResponse(
                protocolVersion: GatewayProtocol.version,
                adapterName: GatewayConfiguration.adapterName,
                adapterVersion: configuration.adapterVersion,
                capabilities: Capabilities()
            ))
        }
        router.post("/v1/deliveries") { request, _ in
            guard authorized(request, token) else { return unauthorized() }
            let body: Data?
            if let buffer = try? await request.body.collect(upTo: GatewayProtocol.maxHTTPBodyBytes) {
                body = Data(buffer: buffer)
            } else {
                body = nil
            }
            let (status, response) = await deliveries.handle(body: body)
            return json(HTTPResponse.Status(code: status), response)
        }
        return router
    }

    private static func authorized(_ request: Request, _ token: String) -> Bool {
        GatewayProtocol.constantTimeEqual(GatewayProtocol.bearerToken(request.headers[.authorization]), token)
    }

    private static func unauthorized() -> Response {
        json(.unauthorized, ["error": "unauthorized"])
    }

    static func json(_ status: HTTPResponse.Status, _ value: some Encodable) -> Response {
        let data = (try? JSONEncoder.gateway().encode(value)) ?? Data("{}".utf8)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }
}

private struct SecurityHeaders<Context: RequestContext>: RouterMiddleware {
    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        var response = try await next(request, context)
        response.headers[.cacheControl] = "no-store"
        response.headers[.contentSecurityPolicy] = "default-src 'none'"
        response.headers[.init("X-Content-Type-Options")!] = "nosniff"
        return response
    }
}

extension Data {
    init(buffer: ByteBuffer) {
        self.init(buffer.readableBytesView)
    }
}
