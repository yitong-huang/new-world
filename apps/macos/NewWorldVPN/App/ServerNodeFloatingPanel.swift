import AppKit
import SwiftUI

/// 在菜单栏 Popover 内用独立浮动面板选择节点（与 `AuthFloatingPanel` 同因）。
enum ServerNodeFloatingPanel {
    private static var panel: NSPanel?

    /// 打开时始终从包内 `servers` 重新加载列表，避免与主界面 `@State` 不同步；列表区须固定高度，否则在 NSPanel 里 ScrollView 常被压成 0 高。
    static func present(
        selectedHost: String,
        onSave: @escaping (String) -> Void,
    ) {
        dismiss()
        let nodes = VPNServerCatalog.loadEntries()
        guard !nodes.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)

        let content = ServerNodePanelContent(
            nodes: nodes,
            selectedHost: selectedHost,
            onSave: { host in
                onSave(host)
                dismiss()
            },
            onCancel: { dismiss() },
        )
        .frame(minWidth: 360)

        let hosting = NSHostingController(rootView: content)
        hosting.view.translatesAutoresizingMaskIntoConstraints = false

        let w: CGFloat = 420
        let listArea = min(300, max(132, CGFloat(nodes.count) * 56 + 24))
        let h: CGFloat = min(520, 140 + listArea + 56)
        let style: NSWindow.StyleMask = [.titled, .closable]
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: style,
            backing: .buffered,
            defer: false,
        )
        p.title = "选择节点"
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

private struct ServerNodePanelContent: View {
    let nodes: [VPNServerEntry]
    @State private var draftHost: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    init(
        nodes: [VPNServerEntry],
        selectedHost: String,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
    ) {
        self.nodes = nodes
        let initial = nodes.contains(where: { $0.host == selectedHost }) ? selectedHost : (nodes.first?.host ?? "")
        _draftHost = State(initialValue: initial)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var listAreaHeight: CGFloat {
        min(300, max(132, CGFloat(nodes.count) * 56 + 24))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("请选择要连接的 host，保存后生效。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // 仅 maxHeight 时，在 NSHostingController + NSPanel 里 ScrollView 高度常被算成 0，列表整段空白。
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(nodes) { node in
                        nodeRow(node)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: listAreaHeight)
            .clipped()

            HStack {
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("保存") {
                    if !draftHost.isEmpty {
                        onSave(draftHost)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draftHost.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
    }

    @ViewBuilder
    private func nodeRow(_ node: VPNServerEntry) -> some View {
        Button {
            draftHost = node.host
        } label: {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(node.host)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                    Text(node.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if draftHost == node.host {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(draftHost == node.host ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        draftHost == node.host ? Color.accentColor.opacity(0.45) : Color(nsColor: .separatorColor),
                        lineWidth: 1,
                    ),
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
