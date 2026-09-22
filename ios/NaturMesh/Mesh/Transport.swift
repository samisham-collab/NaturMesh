import Foundation
import MultipeerConnectivity

/// Anything that can carry packets to neighbours. Multipeer is the first; a residence gateway
/// (satellite or wired uplink) plugs in later as another transport without touching the router.
protocol MeshTransport: AnyObject {
    var delegate: MeshTransportDelegate? { get set }
    var neighbourIDs: [String] { get }
    func start()
    func stop()
    func send(_ data: Data, to neighbours: [String]?)
}

protocol MeshTransportDelegate: AnyObject {
    func transport(_ t: MeshTransport, received data: Data, from neighbour: String)
    func transport(_ t: MeshTransport, neighbourChanged neighbour: String, connected: Bool)
}

/// Apple MultipeerConnectivity: Bluetooth + peer-to-peer Wi-Fi + LAN, encrypted per link, no infrastructure.
final class MultipeerTransport: NSObject, MeshTransport {
    static let serviceType = "naturmesh"

    weak var delegate: MeshTransportDelegate?
    private let peerID: MCPeerID
    private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var running = false

    init(displayName: String) {
        let name = String(displayName.prefix(24)).isEmpty ? "node" : String(displayName.prefix(24))
        peerID = MCPeerID(displayName: name)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: MultipeerTransport.serviceType)
        browser = MCNearbyServiceBrowser(peer: peerID, serviceType: MultipeerTransport.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    var neighbourIDs: [String] { session.connectedPeers.map { $0.displayName + "#" + String($0.hash) } }

    func start() {
        guard !running else { return }
        running = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func stop() {
        running = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
    }

    func send(_ data: Data, to neighbours: [String]?) {
        let targets: [MCPeerID]
        if let neighbours {
            targets = session.connectedPeers.filter { neighbours.contains(key(for: $0)) }
        } else {
            targets = session.connectedPeers
        }
        guard !targets.isEmpty else { return }
        try? session.send(data, toPeers: targets, with: .unreliable)
    }

    private func key(for peer: MCPeerID) -> String { peer.displayName + "#" + String(peer.hash) }
}

extension MultipeerTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer: MCPeerID, didChange state: MCSessionState) {
        let connected = state == .connected
        if state != .connecting {
            delegate?.transport(self, neighbourChanged: key(for: peer), connected: connected)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peer: MCPeerID) {
        delegate?.transport(self, received: data, from: key(for: peer))
    }

    // Streams and resources are how media would get in. They are refused outright.
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        stream.close()
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progress.cancel()
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        if let localURL { try? FileManager.default.removeItem(at: localURL) }
    }
}

extension MultipeerTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Accept everyone at the link layer. Trust is decided per message by signatures and channel keys.
        invitationHandler(session.connectedPeers.count < 7, session)
    }
}

extension MultipeerTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Only the lexically smaller name invites, so two phones don't invite each other at once.
        guard self.peerID.displayName < peerID.displayName || (self.peerID.displayName == peerID.displayName && self.peerID.hash < peerID.hash) else { return }
        guard session.connectedPeers.count < 7, !session.connectedPeers.contains(peerID) else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
