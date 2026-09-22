import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    init() {
        // Tab bar and nav bars in the site's canopy green.
        let tab = UITabBarAppearance(); tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(named: "Canopy")
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab
        let nav = UINavigationBarAppearance(); nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(named: "Canopy")
        nav.shadowColor = .clear
        nav.titleTextAttributes = [.foregroundColor: UIColor(named: "Birch") ?? .white]
        nav.largeTitleTextAttributes = [.foregroundColor: UIColor(named: "Birch") ?? .white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }

    var body: some View {
        TabView {
            MessagesView()
                .tabItem { Label("Mesh", systemImage: "point.3.connected.trianglepath.dotted") }
            NearbyView()
                .tabItem { Label("Nearby", systemImage: "person.2.wave.2") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .overlay(alignment: .top) {
            if let sos = model.activeSOS { SOSBanner(message: sos) }
        }
    }
}

/// The readout, as on the site: carrier state on one side, mesh on the other.
struct LinkStatus: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(model.neighbourCount > 0 ? Brand.signal : Brand.lichen.opacity(0.5)).frame(width: 8, height: 8)
                Text(meshText)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: model.uplink.hasInternet ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                Text(model.uplink.hasInternet ? "\(model.uplink.interfaceName) · gateway" : "no service")
            }
            .foregroundStyle(model.uplink.hasInternet ? Brand.signal : Brand.ember)
        }
        .font(Brand.text(12, weight: .medium))
        .foregroundStyle(Brand.lichen)
    }

    private var meshText: String {
        if !model.running { return "mesh paused" }
        if model.neighbourCount == 0 { return "listening for phones" }
        var s = "\(model.neighbourCount) direct · \(model.peers.count) on mesh"
        if model.gatewayCount > 0 { s += " · \(model.gatewayCount) gateway\(model.gatewayCount == 1 ? "" : "s")" }
        return s
    }
}

struct SOSBanner: View {
    @EnvironmentObject var model: AppModel
    let message: MeshMessage

    var body: some View {
        HStack {
            Image(systemName: "light.beacon.max.fill")
            Text("SOS sent · \(message.sentAt, style: .relative) ago").font(Brand.text(14, weight: .semibold))
            Spacer()
            Button("I'm OK now") { model.cancelSOS() }
                .font(Brand.text(13, weight: .semibold))
                .buttonStyle(.borderedProminent).tint(Brand.birch).foregroundStyle(Brand.ember)
                .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Brand.ember, in: Capsule())
        .foregroundStyle(Brand.birch)
        .padding(.horizontal)
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }
}
