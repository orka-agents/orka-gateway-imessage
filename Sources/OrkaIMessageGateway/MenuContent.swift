import AppKit
import SwiftUI

struct MenuContent: View {
    let controller: GatewayController

    var body: some View {
        Text("Orka iMessage Gateway")
        Text(statusLine)
        if let date = controller.lastForwardedAt {
            Text("Last message to Orka \(date.formatted(.relative(presentation: .named)))")
        }
        if let date = controller.lastRepliedAt {
            Text("Last reply \(date.formatted(.relative(presentation: .named)))")
        }
        if controller.fullDiskAccess != .granted {
            Button("Grant Full Disk Access…") { Permissions.openFullDiskAccessSettings() }
        }
        if controller.automation != .granted {
            Button("Allow Sending with Messages…") {
                Task { await controller.requestAutomation() }
            }
        }
        Divider()
        if controller.isRunning {
            Button("Stop Gateway") {
                Task { await controller.stop() }
            }
        } else {
            Button("Start Gateway") { controller.start() }
                .disabled(!controller.configurationProblems.isEmpty)
        }
        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")
        Toggle("Launch at Login", isOn: Binding(
            get: { controller.launchAtLogin },
            set: { controller.setLaunchAtLogin($0) }
        ))
        Divider()
        Button("Quit") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusLine: String {
        switch controller.runState {
        case let .running(port): "Running on 127.0.0.1:\(port)"
        case .starting: "Starting…"
        case .stopped: controller.configurationProblems.isEmpty ? "Stopped" : "Not configured: open Settings"
        case let .failed(message): "Stopped: \(message)"
        }
    }
}
