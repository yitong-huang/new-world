import SwiftUI

@main
struct NWVPNApp: App {
    @StateObject private var vpn = VPNManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(vpn)
        }
        .defaultSize(width: 420, height: 320)
    }
}
