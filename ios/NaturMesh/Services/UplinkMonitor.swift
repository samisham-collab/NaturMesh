import Foundation
import Network
import Combine

/// Does this phone still have a way out: a live tower, a working Wi-Fi network, a satellite link?
/// If so, it advertises itself as a gateway so the mesh knows where the exit is.
///
/// The path monitor says whether an interface is up; a tiny probe confirms the internet is really behind it,
/// because a surviving access point with no WAN behind it is still a fine mesh bridge but not an exit.
final class UplinkMonitor: ObservableObject {
    @Published private(set) var interfaceUp = false
    @Published private(set) var hasInternet = false
    @Published private(set) var interfaceName = "none"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.naturmesh.uplink")
    private var probeTimer: Timer?
    private var probing = false

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let up = path.status == .satisfied
            let name: String
            if path.usesInterfaceType(.cellular) { name = "cellular" }
            else if path.usesInterfaceType(.wifi) { name = "Wi-Fi" }
            else if path.usesInterfaceType(.wiredEthernet) { name = "wired" }
            else if path.usesInterfaceType(.other) { name = "other" }
            else { name = "none" }
            DispatchQueue.main.async {
                self.interfaceUp = up
                self.interfaceName = up ? name : "none"
                if !up { self.hasInternet = false } else { self.probe() }
            }
        }
        monitor.start(queue: queue)
        probeTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probe() }
        }
    }

    func stop() {
        monitor.cancel()
        probeTimer?.invalidate()
    }

    /// One small request to a captive-portal check page. 5 s timeout, no caching, no retries.
    private func probe() {
        guard interfaceUp, !probing, let url = URL(string: "https://captive.apple.com/hotspot-detect.html") else { return }
        probing = true
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        req.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: req) { [weak self] _, resp, _ in
            let ok = (resp as? HTTPURLResponse).map { (200..<400).contains($0.statusCode) } ?? false
            DispatchQueue.main.async {
                self?.hasInternet = ok
                self?.probing = false
            }
        }.resume()
    }
}
