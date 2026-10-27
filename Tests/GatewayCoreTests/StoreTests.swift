import Foundation
@testable import GatewayCore
import Testing

struct StoreTests {
    @Test func cursorIsMonotonicAndDurable() async throws {
        let path = temporaryStorePath()
        let store = try GatewayStore(path: path)
        let initial = try await store.cursor()
        #expect(initial.rowID == 0 && !initial.initialized)
        try await store.initializeCursor(10)
        try await store.initializeCursor(99)
        #expect(try await store.cursor().rowID == 10)
        try await store.advanceCursor(20)
        try await store.advanceCursor(15)
        #expect(try await store.cursor().rowID == 20)
        await #expect(throws: StoreError.self) { try await store.advanceCursor(0) }
        await #expect(throws: StoreError.self) { try await store.initializeCursor(-1) }

        let reopened = try GatewayStore(path: path)
        let cursor = try await reopened.cursor()
        #expect(cursor.rowID == 20 && cursor.initialized)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func emptyDatabaseCursorIsInitialized() async throws {
        let store = try GatewayStore(path: temporaryStorePath())
        try await store.initializeCursor(0)
        let cursor = try await store.cursor()
        #expect(cursor.rowID == 0 && cursor.initialized)
    }

    @Test func rejectsNonFilesystemPaths() {
        for path in ["", ":memory:", "file:gateway.db"] {
            #expect(throws: StoreError.self) { try GatewayStore(path: path) }
        }
    }

    @Test func remembersReplyChats() async throws {
        let store = try GatewayStore(path: temporaryStorePath())
        #expect(try await !store.replyChatKnown(testChat))
        try await store.rememberReplyChat(testChat)
        try await store.rememberReplyChat(testChat)
        #expect(try await store.replyChatKnown(testChat))
    }

    @Test func deliveryLifecycle() async throws {
        let path = temporaryStorePath()
        let store = try GatewayStore(path: path)
        let text = Digest.text("hello")
        let first = try await store.claimDelivery(idempotencyID: "a", requestDigest: "d1", chatGUID: testChat, textDigest: text)
        #expect(first.shouldSend && first.record.state == .sending)
        let inFlight = try await store.claimDelivery(idempotencyID: "a", requestDigest: "d1", chatGUID: testChat, textDigest: text)
        #expect(!inFlight.shouldSend)
        await #expect(throws: StoreError.digestConflict) {
            try await store.claimDelivery(idempotencyID: "a", requestDigest: "d2", chatGUID: testChat, textDigest: text)
        }
        await #expect(throws: StoreError.invalidTransition) {
            try await store.finishDelivery(idempotencyID: "a", requestDigest: "d1", state: .sending, providerMessageID: "", safeMessage: "")
        }

        let retryable = try await store.finishDelivery(
            idempotencyID: "a", requestDigest: "d1", state: .retryable, providerMessageID: "", safeMessage: "try again"
        )
        #expect(retryable.state == .retryable)
        let reclaimed = try await store.claimDelivery(idempotencyID: "a", requestDigest: "d1", chatGUID: testChat, textDigest: text)
        #expect(reclaimed.shouldSend && reclaimed.record.safeMessage.isEmpty)
        let delivered = try await store.finishDelivery(
            idempotencyID: "a", requestDigest: "d1", state: .delivered, providerMessageID: "MSG", safeMessage: ""
        )
        #expect(delivered.state == .delivered && delivered.providerMessageID == "MSG")
        let replay = try await store.claimDelivery(idempotencyID: "a", requestDigest: "d1", chatGUID: testChat, textDigest: text)
        #expect(!replay.shouldSend && replay.record.state == .delivered)
        await #expect(throws: StoreError.invalidTransition) {
            try await store.finishDelivery(idempotencyID: "a", requestDigest: "d1", state: .unknown, providerMessageID: "", safeMessage: "")
        }

        // A restart turns an interrupted send into a terminal unknown outcome.
        _ = try await store.claimDelivery(idempotencyID: "b", requestDigest: "d1", chatGUID: testChat, textDigest: text)
        let reopened = try GatewayStore(path: path)
        let interrupted = try #require(try await reopened.delivery("b"))
        #expect(interrupted.state == .unknown)
        #expect(interrupted.safeMessage == GatewayStore.outcomeUnknownAfterRestart)
        #expect(try await reopened.delivery("a")?.state == .delivered)
    }

    @Test func sentNearMatchesTheRowTime() async throws {
        let store = try GatewayStore(path: temporaryStorePath())
        let text = Digest.text("hello")
        _ = try await store.claimDelivery(idempotencyID: "a", requestDigest: "d", chatGUID: testChat, textDigest: text)
        let now = Date()
        #expect(try await store.sentNear(chatGUID: testChat, textDigest: text, at: now, window: 120))
        #expect(try await store.sentNear(chatGUID: testChat, textDigest: text, at: now.addingTimeInterval(-100), window: 120))
        #expect(try await !store.sentNear(chatGUID: testChat, textDigest: text, at: now.addingTimeInterval(-300), window: 120))
        #expect(try await !store.sentNear(chatGUID: testChat, textDigest: text, at: now.addingTimeInterval(300), window: 120))
        #expect(try await !store.sentNear(chatGUID: testChat, textDigest: Digest.text("other"), at: now, window: 120))
        #expect(try await !store.sentNear(chatGUID: "iMessage;-;+14155550000", textDigest: text, at: now, window: 120))

        // A retryable (never dispatched) delivery has no echo.
        _ = try await store.finishDelivery(idempotencyID: "a", requestDigest: "d", state: .retryable, providerMessageID: "", safeMessage: "")
        #expect(try await !store.sentNear(chatGUID: testChat, textDigest: text, at: now, window: 120))
    }

    @Test func outgoingRowsMatchExactly() async throws {
        let store = try GatewayStore(path: temporaryStorePath())
        let text = Digest.text("hello")
        let created = Date(timeIntervalSince1970: 1_800_000_000.123)
        try await store.recordOutgoingRow(chatGUID: testChat, textDigest: text, createdAt: created)
        try await store.recordOutgoingRow(chatGUID: testChat, textDigest: text, createdAt: created)
        #expect(try await store.hasOutgoingRow(chatGUID: testChat, textDigest: text, createdAt: created))
        #expect(try await !store.hasOutgoingRow(chatGUID: testChat, textDigest: text, createdAt: created.addingTimeInterval(-0.1)))
        #expect(try await !store.hasOutgoingRow(chatGUID: testChat, textDigest: Digest.text("other"), createdAt: created))
    }

    @Test func textDigestNormalizesEdgesAndLineEndings() {
        #expect(Digest.text(" a\r\nb \n") == Digest.text("a\nb"))
        #expect(Digest.text("a") != Digest.text("b"))
    }
}
