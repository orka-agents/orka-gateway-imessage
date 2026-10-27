import AppKit
import CoreServices
import Foundation

enum PermissionState: Equatable {
    case granted
    case denied
    case notDetermined
    case unknown
}

/// Full Disk Access (to read Messages' database) and Automation for Messages
/// (to send), both checked for this app.
enum Permissions {
    static let messagesBundleID = "com.apple.MobileSMS"

    static var messagesDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/chat.db").path
    }

    /// Opening the database is the only reliable check; macOS has no API for it.
    static func fullDiskAccess() -> PermissionState {
        let descriptor = Darwin.open(messagesDatabasePath, O_RDONLY)
        if descriptor >= 0 {
            Darwin.close(descriptor)
            return .granted
        }
        return errno == EPERM || errno == EACCES ? .denied : .unknown
    }

    /// Checks, or with `ask` requests, permission to send Apple events to
    /// Messages. Asking blocks until the user answers, so it runs off the main
    /// thread, and it launches Messages in the background when needed.
    static func automation(ask: Bool) async -> PermissionState {
        if ask, NSRunningApplication.runningApplications(withBundleIdentifier: messagesBundleID).isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: messagesBundleID)
        {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let target = NSAppleEventDescriptor(bundleIdentifier: messagesBundleID)
                let status = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, ask)
                let state: PermissionState = switch status {
                case noErr: .granted
                case OSStatus(errAEEventNotPermitted): .denied
                case OSStatus(errAEEventWouldRequireUserConsent): .notDetermined
                default: .unknown
                }
                continuation.resume(returning: state)
            }
        }
    }

    static func openFullDiskAccessSettings() {
        openLink("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    static func openAutomationSettings() {
        openLink("x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")
    }

    private static func openLink(_ link: String) {
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }
}
