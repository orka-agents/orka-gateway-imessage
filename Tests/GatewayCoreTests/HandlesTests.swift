@testable import GatewayCore
import Testing

struct HandlesTests {
    @Test(arguments: [
        ("+14155551212", "+14155551212"),
        (" +14155551212 ", "+14155551212"),
        ("Me@Example.COM", "me@example.com"),
    ])
    func normalizesHandles(raw: String, expected: String) throws {
        #expect(try Handles.normalize(raw) == expected)
    }

    @Test(arguments: [
        "", "4155551212", "+1415", "+1234567890123456", "+1415555121a", "@example.com", "me@", "me@@example.com",
        "m e@example.com", "a@b@c",
    ])
    func rejectsInvalidHandles(raw: String) {
        #expect(throws: HandleError.self) { try Handles.normalize(raw) }
    }

    @Test func allowlistIsRequiredAndNormalized() throws {
        #expect(throws: HandleError.self) { try Allowlist(parsing: " , ") }
        #expect(throws: HandleError.self) { try Allowlist(parsing: "+14155551212, 4155551212") }
        let allowlist = try Allowlist(parsing: "+14155551212, Me@Example.com\nother@example.com")
        #expect(allowlist.count == 3)
        #expect(allowlist.contains("me@example.com"))
        #expect(allowlist.contains(" +14155551212"))
        #expect(!allowlist.contains("+14155551213"))
        #expect(!allowlist.contains("not a handle"))
    }

    @Test func parsesChatGUIDs() throws {
        let direct = try ChatGUID(parsing: "iMessage;-;+14155551212")
        #expect(direct.service == "iMessage")
        #expect(!direct.isGroup)
        #expect(direct.identifier == "+14155551212")
        let any = try ChatGUID(parsing: "any;-;me@example.com")
        #expect(any.identifier == "me@example.com")
        let group = try ChatGUID(parsing: "iMessage;+;chat123;extra")
        #expect(group.isGroup)
        #expect(group.identifier == "chat123;extra")
        for invalid in ["", "iMessage", "iMessage;x;id", ";-;id", "iMessage;-;", "iMessage;-; id", " iMessage;-;id"] {
            #expect(throws: HandleError.self) { try ChatGUID(parsing: invalid) }
        }
    }
}
