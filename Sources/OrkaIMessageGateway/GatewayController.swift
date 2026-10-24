import AppKit
import Foundation
import GatewayCore
import Logging
import MessagesBridge
import Observation
import ServiceManagement

struct ActivityEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
    let isWarning: Bool
}

/// Owns the gateway's lifecycle and the state the menu and settings show.
@MainActor
@Observable
final class GatewayController {
    enum RunState: Equatable {
        case stopped
        case starting
        case running(port: Int)
        case failed(String)
    }

    private(set) var settings = GatewaySettings.load()
    private(set) var inboundToken = TokenStore.read(TokenStore.inboundAccount)
    private(set) var outboundToken = TokenStore.read(TokenStore.outboundAccount)
    private(set) var runState = RunState.stopped
    private(set) var fullDiskAccess = PermissionState.unknown
    private(set) var automation = PermissionState.unknown
    private(set) var lastForwardedAt: Date?
    private(set) var lastRepliedAt: Date?
    private(set) var activity: [ActivityEntry] = []
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var runTask: Task<Void, Never>?
    private let logger = Logger(label: "app")

    var isRunning: Bool {
        switch runState {
        case .starting, .running: true
        case .stopped, .failed: false
        }
    }

    var needsPermissions: Bool {
        fullDiskAccess != .granted || automation != .granted
    }

    /// Validation problems with the saved settings, if any.
    var configurationProblems: [String] {
        do {
            _ = try configuration()
            return []
        } catch let error as ConfigurationError {
            return error.problems
        } catch {
            return ["\(error)"]
        }
    }

    func launch() {
        Task {
            await refreshPermissions()
            if settings.startAutomatically, configurationProblems.isEmpty, fullDiskAccess == .granted {
                start()
            }
        }
    }

    func start() {
        guard runTask == nil else { return }
        let configuration: GatewayConfiguration
        do {
            configuration = try self.configuration()
        } catch {
            runState = .failed("\(error)")
            return
        }
        fullDiskAccess = Permissions.fullDiskAccess()
        guard fullDiskAccess == .granted else {
            runState = .failed("Full Disk Access is required to read Messages.")
            return
        }
        let store: GatewayStore
        do {
            store = try GatewayStore(path: Self.databaseURL.path)
        } catch {
            runState = .failed("Could not open the gateway database: \(error)")
            return
        }
        let runtime = GatewayRuntime(
            configuration: configuration,
            store: store,
            backend: IMsgBackend(),
            logger: Logger(label: "gateway"),
            observer: { [weak self] activity in
                Task { @MainActor in self?.record(activity) }
            }
        )
        runState = .starting
        runTask = Task {
            var failure: String?
            do {
                try await runtime.run()
            } catch is CancellationError {
            } catch {
                failure = "\(error)"
            }
            self.runTask = nil
            if let failure {
                self.runState = .failed(failure)
                self.append("Gateway stopped: \(failure)", warning: true)
            } else {
                self.runState = .stopped
                self.append("Gateway stopped", warning: false)
            }
        }
    }

    func stop() async {
        guard let runTask else { return }
        runTask.cancel()
        await runTask.value
    }

    /// Saves settings and tokens, restarting the gateway if it was running.
    func apply(settings: GatewaySettings, inboundToken: String, outboundToken: String) async throws {
        try TokenStore.write(inboundToken, account: TokenStore.inboundAccount)
        try TokenStore.write(outboundToken, account: TokenStore.outboundAccount)
        settings.save()
        let wasRunning = isRunning
        await stop()
        self.settings = settings
        self.inboundToken = inboundToken
        self.outboundToken = outboundToken
        if wasRunning || settings.startAutomatically {
            start()
        }
    }

    func refreshPermissions() async {
        fullDiskAccess = Permissions.fullDiskAccess()
        automation = await Permissions.automation(ask: false)
    }

    func requestAutomation() async {
        automation = await Permissions.automation(ask: true)
        if automation == .denied {
            Permissions.openAutomationSettings()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            append("Could not change Launch at Login: \(error.localizedDescription)", warning: true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func configuration() throws -> GatewayConfiguration {
        try GatewayConfiguration(
            accountID: settings.accountID,
            allowedSenders: settings.allowedSenders,
            ingressURL: settings.ingressURL,
            inboundToken: inboundToken,
            outboundToken: outboundToken,
            listenHost: "127.0.0.1",
            listenPort: settings.listenPort,
            adapterVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        )
    }

    private func record(_ event: GatewayActivity) {
        switch event {
        case let .listening(host, port):
            runState = .running(port: port)
            append("Listening on \(host):\(port)", warning: false)
        case let .watching(rowID):
            append("Watching Messages after row \(rowID)", warning: false)
        case let .watchEnded(detail):
            append("Messages watch restarted: \(detail)", warning: true)
        case let .forwarded(_, chatGUID, _):
            lastForwardedAt = Date()
            append("Forwarded a message from \(chatGUID) to Orka", warning: false)
        case .skipped:
            break
        case let .ingressRetrying(_, detail):
            append("Orka unavailable, retrying: \(detail)", warning: true)
        case let .ingressRejected(_, detail):
            append("Orka rejected a message: \(detail)", warning: true)
        case let .delivered(kind, state):
            if state == .delivered {
                lastRepliedAt = Date()
                append(kind == "message" ? "Sent a progress update" : "Sent a reply", warning: false)
            } else {
                append("Reply not sent (\(state.rawValue))", warning: true)
            }
        case let .deliveryRejected(reason):
            append("Refused a delivery: \(reason)", warning: true)
        }
    }

    private func append(_ text: String, warning: Bool) {
        activity.insert(ActivityEntry(date: Date(), text: text, isWarning: warning), at: 0)
        if activity.count > 100 {
            activity.removeLast(activity.count - 100)
        }
        if warning {
            logger.warning("\(text)")
        }
    }

    static var databaseURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ai.orka.gateway-imessage", isDirectory: true)
            .appendingPathComponent("gateway.db")
    }
}
