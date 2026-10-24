import AppKit
import Logging
import os
import SwiftUI

@main
struct OrkaIMessageGatewayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: appDelegate.controller)
        } label: {
            Image(systemName: appDelegate.controller.menuSymbol)
        }
        Settings {
            SettingsView(controller: appDelegate.controller)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: GatewayController

    override init() {
        LoggingSystem.bootstrap { OSLogHandler(label: $0) }
        controller = GatewayController()
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        controller.launch()
    }

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard controller.isRunning else { return .terminateNow }
        Task {
            await controller.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

extension GatewayController {
    var menuSymbol: String {
        switch runState {
        case .running: needsPermissions ? "exclamationmark.bubble" : "message.fill"
        case .starting: "message"
        case .stopped: "message"
        case .failed: "exclamationmark.bubble"
        }
    }
}

/// Sends swift-log records to the unified log. Records never contain message text.
struct OSLogHandler: LogHandler {
    var metadata: Logging.Logger.Metadata = [:]
    // Debug records, such as why a message was skipped, are kept in memory
    // only; view them with `log stream --level debug`.
    var logLevel: Logging.Logger.Level = .debug
    private let logger: os.Logger

    init(label: String) {
        logger = os.Logger(subsystem: "ai.orka.gateway-imessage", category: label)
    }

    subscript(metadataKey key: String) -> Logging.Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        let details = merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let text = details.isEmpty ? "\(event.message)" : "\(event.message) \(details)"
        switch event.level {
        case .trace, .debug: logger.debug("\(text, privacy: .public)")
        case .info, .notice: logger.info("\(text, privacy: .public)")
        case .warning: logger.warning("\(text, privacy: .public)")
        case .error, .critical: logger.error("\(text, privacy: .public)")
        }
    }
}
