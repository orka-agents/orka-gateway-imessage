import Foundation
@testable import GatewayCore
import Testing

private struct Harness {
    let store: GatewayStore
    let backend = FakeBackend()
    let ingress = FakeIngress()
    let forwarder: InboundForwarder

    init(storePath: String = temporaryStorePath()) throws {
        store = try GatewayStore(path: storePath)
        forwarder = InboundForwarder(
            configuration: try testConfiguration(), store: store, backend: backend, ingress: ingress,
            logger: quietLogger, observer: { _ in }, maxBackoff: 0.001
        )
    }

    func run(_ messages: [IncomingMessage]) async throws {
        backend.queued.withLock { $0 = messages }
        try await forwarder.watchOnce()
    }
}

struct InboundTests {
    @Test func forwardsAllowlistedText() async throws {
        let harness = try Harness()
        let created = Date().addingTimeInterval(-5)
        try await harness.run([message(1, text: "  hi\u{FFFC} there\u{07} ", createdAt: created)])
        let events = harness.ingress.events.current
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.protocolVersion == "orka.gateway.v1")
        #expect(event.externalEventId == "MSG-1")
        #expect(event.eventType == "text")
        #expect(event.accountId == "mac-messages")
        #expect(event.contextId == testChat)
        #expect(event.replyTarget == testChat)
        #expect(event.sender == EventSender(id: testHandle))
        #expect(event.text == "hi there")
        #expect(event.occurredAt == created)
        #expect(try await harness.store.replyChatKnown(testChat))
        #expect(try await harness.store.cursor().rowID == 1)
    }

    @Test func skipsEverythingElse() async throws {
        let harness = try Harness()
        var reaction = message(3)
        reaction.isReaction = true
        var poll = message(4)
        poll.isPoll = true
        let rows = [
            message(2, isFromMe: true),
            reaction,
            poll,
            message(5, chat: "iMessage;+;chat123"),
            message(6, chat: "iMessage;-;+14155550000", sender: "+14155550000"),
            message(7, sender: "+14155550000"),
            message(8, text: " \u{FFFC} "),
            message(9, text: String(repeating: "a", count: (64 << 10) + 1)),
            message(10, chat: "not a chat"),
            message(11, createdAt: Date().addingTimeInterval(-25 * 60 * 60)),
        ]
        try await harness.run(rows)
        #expect(harness.ingress.events.current.isEmpty)
        #expect(try await harness.store.cursor().rowID == 11)
        #expect(try await !harness.store.replyChatKnown("iMessage;-;+14155550000"))
    }

    @Test func mutationsNeverAdvanceTheCursor() async throws {
        let harness = try Harness()
        try await harness.store.initializeCursor(5)
        var edit = message(9)
        edit.isMutation = true
        try await harness.forwarder.handle(edit)
        #expect(harness.ingress.events.current.isEmpty)
        #expect(try await harness.store.cursor().rowID == 5)
    }

    @Test func suppressesEchoesOfGatewaySends() async throws {
        let harness = try Harness()
        _ = try await harness.store.claimDelivery(
            idempotencyID: "a", requestDigest: "d", chatGUID: testChat, textDigest: Digest.text("agent reply")
        )
        try await harness.run([
            message(1, text: "agent reply\r\n", createdAt: Date()),
            message(2, text: "agent reply", createdAt: Date().addingTimeInterval(-600)),
            message(3, text: "user text", createdAt: Date()),
        ])
        #expect(harness.ingress.events.current.map(\.externalEventId) == ["MSG-2", "MSG-3"])
    }

    @Test func forwardsOneRowPerSelfChatSend() async throws {
        let harness = try Harness()
        let sent = Date().addingTimeInterval(-10)
        try await harness.run([
            message(1, text: "hello", createdAt: sent, isFromMe: true),
            // The received copy carrying the outgoing row's exact time.
            message(2, text: "hello", createdAt: sent),
            // The copy delivered to the handle, stamped slightly earlier.
            message(3, text: "hello", createdAt: sent.addingTimeInterval(-0.2)),
            // A repeat of the same text is a new message.
            message(4, text: "hello", createdAt: sent.addingTimeInterval(5), isFromMe: true),
            message(5, text: "hello", createdAt: sent.addingTimeInterval(4.9)),
        ])
        #expect(harness.ingress.events.current.map(\.externalEventId) == ["MSG-3", "MSG-5"])
    }

    @Test func retriesTransientIngressAndSkipsRejectedEvents() async throws {
        let harness = try Harness()
        harness.ingress.failures.withLock {
            $0 = [.transient("down"), .transient("still down"), .permanent(status: 422)]
        }
        try await harness.run([message(1), message(2)])
        // Row 1 was attempted three times and admitted; row 2 was rejected once.
        #expect(harness.ingress.events.current.map(\.externalEventId) == ["MSG-1", "MSG-1", "MSG-1", "MSG-2"])
        #expect(try await harness.store.cursor().rowID == 2)
    }

    @Test func cancellationDuringRetryKeepsTheRow() async throws {
        let store = try GatewayStore(path: temporaryStorePath())
        let backend = FakeBackend()
        let ingress = FakeIngress()
        ingress.failures.withLock { $0 = Array(repeating: .transient("down"), count: 1000) }
        let forwarder = InboundForwarder(
            configuration: try testConfiguration(), store: store, backend: backend, ingress: ingress,
            logger: quietLogger, observer: { _ in }, maxBackoff: 0.01
        )
        try await store.initializeCursor(0)
        let task = Task { try await forwarder.handle(message(1)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await store.cursor().rowID == 0)
    }

    @Test func watchResumesFromTheDurableCursor() async throws {
        let harness = try Harness()
        try await harness.store.initializeCursor(42)
        harness.backend.latest.withLock { $0 = 100 }
        try await harness.run([])
        #expect(harness.backend.watchCursors.current == [42])
    }

    @Test func firstStartPersistsTheNewestRow() async throws {
        let path = temporaryStorePath()
        let harness = try Harness(storePath: path)
        harness.backend.latest.withLock { $0 = 100 }
        try await harness.run([message(100), message(101)])
        #expect(harness.backend.watchCursors.current == [100])
        #expect(harness.ingress.events.current.map(\.externalEventId) == ["MSG-101"])
        // A restart resumes from the stored cursor rather than the newest row.
        let restarted = try Harness(storePath: path)
        restarted.backend.latest.withLock { $0 = 500 }
        try await restarted.run([])
        #expect(restarted.backend.watchCursors.current == [101])
    }

    @Test func emptyDatabaseReplaysFromTheFirstRow() async throws {
        let harness = try Harness()
        try await harness.run([message(1)])
        #expect(harness.backend.watchCursors.current == [-1])
        #expect(harness.ingress.events.current.count == 1)
    }

    @Test func runResubscribesAfterTheWatchEnds() async throws {
        let store = try GatewayStore(path: temporaryStorePath())
        let backend = FakeBackend()
        let forwarder = InboundForwarder(
            configuration: try testConfiguration(), store: store, backend: backend, ingress: FakeIngress(),
            logger: quietLogger, observer: { _ in }, maxBackoff: 0.001
        )
        let task = Task { await forwarder.run() }
        for _ in 0 ..< 200 where backend.watchCursors.current.count < 3 {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        task.cancel()
        await task.value
        #expect(backend.watchCursors.current.count >= 3)
    }
}
