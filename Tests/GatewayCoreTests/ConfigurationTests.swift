@testable import GatewayCore
import Testing

struct ConfigurationTests {
    private func configuration(
        accountID: String = "mac-messages",
        allowedSenders: String = testHandle,
        conformanceChat: String? = nil,
        ingressURL: String = "https://orka.example.com/api/v1/gateways/orka/imessage/events",
        inboundToken: String = "inbound",
        outboundToken: String = "outbound",
        listenPort: Int = 8787
    ) throws -> GatewayConfiguration {
        try GatewayConfiguration(
            accountID: accountID, allowedSenders: allowedSenders, conformanceChatGUID: conformanceChat,
            ingressURL: ingressURL, inboundToken: inboundToken, outboundToken: outboundToken, listenPort: listenPort
        )
    }

    @Test func acceptsSafeConfiguration() throws {
        let valid = try configuration(conformanceChat: testChat)
        #expect(valid.conformanceChatGUID == testChat)
        #expect(valid.allowlist.count == 1)
        _ = try configuration(ingressURL: "http://127.0.0.1:8081/api/v1/gateways/orka/imessage/events")
        _ = try configuration(ingressURL: "http://localhost:8081/api/v1/gateways/orka/imessage/events/")
        #expect(try configuration(conformanceChat: " ").conformanceChatGUID == nil)
    }

    @Test(arguments: [
        "orka.example.com/api/v1/gateways/orka/imessage/events",
        "ftp://orka.example.com/api/v1/gateways/orka/imessage/events",
        "http://orka.example.com/api/v1/gateways/orka/imessage/events",
        "http://10.0.0.1/api/v1/gateways/orka/imessage/events",
        "https://user:pass@orka.example.com/api/v1/gateways/orka/imessage/events",
        "https://orka.example.com/api/v1/gateways/orka/imessage/events?x=1",
        "https://orka.example.com/api/v1/gateways/orka/imessage/events#f",
        "https://orka.example.com/api/v1/gateways/orka/events",
        "https://orka.example.com/api/v1/gateways//imessage/events",
        "https://orka.example.com/v1/gateways/orka/imessage/events",
    ])
    func rejectsUnsafeIngressURLs(url: String) {
        #expect(throws: ConfigurationError.self) { try configuration(ingressURL: url) }
    }

    @Test func rejectsUnsafeConfiguration() {
        #expect(throws: ConfigurationError.self) { try configuration(accountID: "") }
        #expect(throws: ConfigurationError.self) { try configuration(accountID: "bad\u{07}id") }
        #expect(throws: ConfigurationError.self) { try configuration(allowedSenders: "") }
        #expect(throws: ConfigurationError.self) { try configuration(allowedSenders: "4155551212") }
        #expect(throws: ConfigurationError.self) { try configuration(inboundToken: "") }
        #expect(throws: ConfigurationError.self) { try configuration(inboundToken: "same", outboundToken: "same") }
        #expect(throws: ConfigurationError.self) { try configuration(conformanceChat: "iMessage;-;+14155550000") }
        #expect(throws: ConfigurationError.self) { try configuration(conformanceChat: "iMessage;+;\(testHandle)") }
        #expect(throws: ConfigurationError.self) { try configuration(listenPort: 0) }
    }

    @Test func reportsEveryProblem() {
        do {
            _ = try configuration(accountID: "", allowedSenders: "", inboundToken: "")
            Issue.record("configuration was accepted")
        } catch let error as ConfigurationError {
            #expect(error.problems.count == 3)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}
