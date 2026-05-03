import AppKit
import SwiftUI

/// 在菜单栏 Popover 内，`.sheet` / 嵌套 `.popover` 常无法弹出；用独立浮动面板承载认证表单。
enum AuthFloatingPanel {
    private static var panel: NSPanel?

    static func present(
        username: String,
        password: String,
        includeWhenConnecting: Bool,
        onSave: @escaping (String, String, Bool) -> Void,
    ) {
        dismiss()
        NSApp.activate(ignoringOtherApps: true)

        let content = AuthCredentialsPanelContent(
            username: username,
            password: password,
            includeWhenConnecting: includeWhenConnecting,
            onSave: { u, p, i in
                onSave(u, p, i)
                dismiss()
            },
            onCancel: {
                dismiss()
            },
        )
        .frame(minWidth: 380)

        let hosting = NSHostingController(rootView: content)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        let w: CGFloat = 400
        let h: CGFloat = 260
        let style: NSWindow.StyleMask = [.titled, .closable]
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: style,
            backing: .buffered,
            defer: false,
        )
        p.title = "认证信息"
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        p.contentViewController = hosting
        p.isReleasedWhenClosed = false
        p.center()
        p.makeKeyAndOrderFront(nil)
        panel = p
    }

    static func dismiss() {
        panel?.close()
        panel = nil
    }
}

private struct AuthCredentialsPanelContent: View {
    @State private var draftUsername: String
    @State private var draftPassword: String
    @State private var draftInclude: Bool
    let onSave: (String, String, Bool) -> Void
    let onCancel: () -> Void

    init(
        username: String,
        password: String,
        includeWhenConnecting: Bool,
        onSave: @escaping (String, String, Bool) -> Void,
        onCancel: @escaping () -> Void,
    ) {
        _draftUsername = State(initialValue: username)
        _draftPassword = State(initialValue: password)
        _draftInclude = State(initialValue: includeWhenConnecting)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("用户名", text: $draftUsername)
                .textFieldStyle(.roundedBorder)

            SecureField("密码", text: $draftPassword)
                .textFieldStyle(.roundedBorder)

            Toggle("连接时携带认证信息（-auth-file）", isOn: $draftInclude)

            HStack {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("保存") {
                    onSave(draftUsername, draftPassword, draftInclude)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}
