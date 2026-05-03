import SwiftUI

@main
struct NewWorldVPNApp: App {
    @StateObject private var tunnel = TunnelController()

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(true)) {
            ContentView()
                .environmentObject(tunnel)
        } label: {
            Image(systemName: tunnel.isConnected ? "network.badge.shield.half.filled" : "network")
        }
        .menuBarExtraStyle(.automatic)
    }
}
