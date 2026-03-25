import AppKit
import SwiftUI

struct PermissionGateView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Prepare Local Access")
                    .font(.largeTitle.weight(.semibold))
                Text("Before setup starts, you can open the macOS privacy panes for Messages history and sending permissions. After granting access, restart Responder and then begin onboarding. macOS applies Full Disk Access per user login and per app path—switching accounts or opening a different copy (for example from Xcode vs /Applications) means choosing Responder again in System Settings for that setup.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Recommended before setup") {
                VStack(alignment: .leading, spacing: 14) {
                    permissionRow(
                        title: "Full Disk Access",
                        detail: model.messagesAccessRestricted ? model.startupIssues.first ?? "Required for reading local Messages history." : "Messages history access currently looks available.",
                        actionTitle: "Open Full Disk Access"
                    ) {
                        openSystemSettings(anchor: "Privacy_AllFiles")
                    }

                    permissionRow(
                        title: "Messages Folder Access",
                        detail: model.messagesDirectoryAccessPath ?? "Fallback access if Full Disk Access still does not let Responder read chat.db.",
                        actionTitle: model.messagesDirectoryAccessPath == nil ? "Choose Messages Folder" : "Choose Again"
                    ) {
                        Task { await model.chooseMessagesFolder() }
                    }

                    permissionRow(
                        title: "Automation",
                        detail: "Needed only for sending through Messages. Draft suggestions work without it.",
                        actionTitle: "Open Automation"
                    ) {
                        openSystemSettings(anchor: "Privacy_Automation")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("What happens next") {
                VStack(alignment: .leading, spacing: 10) {
                    Label("Grant permissions if you want live Messages access or sending", systemImage: "lock.shield")
                    Label("If Full Disk Access still fails, choose the Messages folder directly", systemImage: "folder.badge.gearshape")
                    Label("Restart Responder after changing Full Disk Access", systemImage: "arrow.clockwise")
                    Label("Then start onboarding to choose a model, seed voice memory, and review autonomy defaults", systemImage: "list.bullet.rectangle")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("I’ll Restart First") {
                    Task { await model.deferOnboardingForPermissions() }
                }

                Spacer()

                Button("Start Setup Now") {
                    Task { await model.enterOnboardingFlow() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 780, height: 520, alignment: .topLeading)
        .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(radius: 30)
    }

    private func permissionRow(
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(actionTitle, action: action)
        }
    }

    private func openSystemSettings(anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
