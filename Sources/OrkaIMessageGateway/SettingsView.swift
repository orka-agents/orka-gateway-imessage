import AppKit
import SwiftUI

struct SettingsView: View {
    let controller: GatewayController

    var body: some View {
        TabView {
            GeneralSettings(controller: controller)
                .tabItem { Label("General", systemImage: "gearshape") }
            PermissionSettings(controller: controller)
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
            ActivityLog(controller: controller)
                .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
        }
        .frame(width: 560, height: 520)
        .onAppear { NSApp.activate() }
    }
}

private struct GeneralSettings: View {
    let controller: GatewayController
    @State private var draft = GatewaySettings()
    @State private var inboundToken = ""
    @State private var outboundToken = ""
    @State private var error: String?

    var body: some View {
        Form {
            Section("Orka") {
                TextField("Account ID", text: $draft.accountID, prompt: Text("my-mac-messages"))
                TextField("Event endpoint", text: $draft.ingressURL,
                          prompt: Text("https://orka.example.com/api/v1/gateways/orka-system/imessage/events"))
                TextField("Local port", value: $draft.listenPort, format: .number.grouping(.never))
                Text("Point your HTTPS tunnel at http://127.0.0.1:\(String(draft.listenPort)).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TextField("Allowed senders", text: $draft.allowedSenders, prompt: Text("+14155551212, you@example.com"),
                          axis: .vertical)
                    .lineLimit(2 ... 4)
            } header: {
                Text("Allowed senders")
            } footer: {
                Text("Only these handles reach Orka, and replies go only to direct chats with them. Use E.164 phone numbers or email addresses.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                TokenField(title: "Inbound token", value: $inboundToken)
                TokenField(title: "Outbound token", value: $outboundToken)
                Button("Generate New Tokens") {
                    inboundToken = TokenStore.generate()
                    outboundToken = TokenStore.generate()
                }
            } header: {
                Text("Orka tokens")
            } footer: {
                Text("Store the same values in Orka's imessage-gateway-inbound and imessage-gateway-outbound Secrets. Tokens are kept in your keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Start the gateway automatically", isOn: $draft.startAutomatically)
                if let error {
                    Text(error).foregroundStyle(.red)
                }
                ForEach(problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Revert") { load() }
                        .disabled(!isDirty)
                    Button(controller.isRunning ? "Save and Restart" : "Save") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isDirty)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { load() }
    }

    private var isDirty: Bool {
        draft != controller.settings || inboundToken != controller.inboundToken || outboundToken != controller.outboundToken
    }

    /// Problems with the saved settings, shown until the draft is saved.
    private var problems: [String] {
        isDirty ? [] : controller.configurationProblems
    }

    private func load() {
        draft = controller.settings
        inboundToken = controller.inboundToken
        outboundToken = controller.outboundToken
        error = nil
    }

    private func save() {
        Task {
            do {
                try await controller.apply(settings: draft, inboundToken: inboundToken, outboundToken: outboundToken)
                error = nil
            } catch {
                self.error = "Could not save: \(error)"
            }
        }
    }
}

private struct TokenField: View {
    let title: String
    @Binding var value: String

    var body: some View {
        HStack {
            SecureField(title, text: $value)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy \(title.lowercased())")
            .disabled(value.isEmpty)
        }
    }
}

private struct PermissionSettings: View {
    let controller: GatewayController

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Full Disk Access",
                    detail: "Reads new messages from the Messages database.",
                    state: controller.fullDiskAccess,
                    actionTitle: "Open Settings…"
                ) {
                    Permissions.openFullDiskAccessSettings()
                }
                PermissionRow(
                    title: "Automation: Messages",
                    detail: "Sends replies through Messages. Allow it before Orka replies, or the first reply can be lost.",
                    state: controller.automation,
                    actionTitle: controller.automation == .denied ? "Open Settings…" : "Allow…"
                ) {
                    Task { await controller.requestAutomation() }
                }
            } footer: {
                Text("macOS grants these to this app. After changing Full Disk Access, quit and reopen the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Check Again") {
                        Task { await controller.refreshPermissions() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await controller.refreshPermissions() }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let state: PermissionState
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: state == .granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(state == .granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if state != .granted {
                Button(actionTitle, action: action)
            }
        }
    }
}

private struct ActivityLog: View {
    let controller: GatewayController

    var body: some View {
        if controller.activity.isEmpty {
            ContentUnavailableView("No activity yet", systemImage: "list.bullet.rectangle",
                                   description: Text("Gateway events appear here. Message text is never shown or logged."))
        } else {
            List(controller.activity) { entry in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: entry.isWarning ? "exclamationmark.triangle" : "circle.fill")
                        .foregroundStyle(entry.isWarning ? .orange : .secondary)
                        .imageScale(.small)
                    Text(entry.text)
                    Spacer()
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }
}
