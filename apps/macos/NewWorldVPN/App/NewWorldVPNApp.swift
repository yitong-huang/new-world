import SwiftUI

@main
struct NewWorldVPNApp: App {
    @StateObject private var tunnel = TunnelController()

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(true)) {
            ContentView()
                .environmentObject(tunnel)
        } label: {
            Image(tunnel.isConnected ? "MenuBarBrickConnected" : "MenuBarBrickDisconnected")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: 14)
                .accessibilityLabel(tunnel.isConnected ? "已连接" : "未连接")
        }
        .menuBarExtraStyle(.automatic)
    }
}
