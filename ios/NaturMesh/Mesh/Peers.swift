import Foundation

/// What we know about another node, learned only from messages it signed.
struct Peer: Identifiable, Equatable {
    let id: NodeID
    var name: String
    var lastSeen: Date
    var direct: Bool
    var hops: Int
    var battery: UInt8?
    var position: GeoPoint?
    var positionAt: Date?
    var lastStatus: CheckInStatus?
    var lastStatusAt: Date?
    var isGateway = false
    /// X25519 public key learned from a signed hello. Needed before a direct message can be sent.
    var agreementKey: Data?

    var displayName: String { name.isEmpty ? "Node " + id.short : name }
}

/// Thread-safe: written from the mesh queue, read from the main thread.
final class PeerDirectory {
    private var storage: [NodeID: Peer] = [:]
    private let lock = NSLock()

    var peers: [NodeID: Peer] { lock.lock(); defer { lock.unlock() }; return storage }

    func observe(_ packet: Packet, payload: Payload?, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        let id = packet.sender
        let peers = storage
        var p = peers[id] ?? Peer(id: id, name: "", lastSeen: now, direct: false, hops: Int(packet.hopCount))
        p.lastSeen = now
        p.direct = packet.hopCount == 0
        p.hops = Int(packet.hopCount)

        switch payload {
        case .position(let geo, let battery, let name):
            p.position = geo; p.positionAt = now; p.battery = battery; if !name.isEmpty { p.name = name }
        case .sos(let geo, let battery, let name, _):
            if let geo { p.position = geo; p.positionAt = now }
            p.battery = battery; if !name.isEmpty { p.name = name }
            p.lastStatus = .needHelp; p.lastStatusAt = now
        case .checkIn(let status, let geo, let battery, let name):
            if let geo { p.position = geo; p.positionAt = now }
            p.battery = battery; if !name.isEmpty { p.name = name }
            p.lastStatus = status; p.lastStatusAt = now
        case .gatewayAdvert(let name):
            p.isGateway = true; if !name.isEmpty { p.name = name }
        case .hello(let name, let key, let battery, let gateway):
            if !name.isEmpty { p.name = name }
            p.agreementKey = key; p.battery = battery; p.isGateway = gateway
        default:
            break
        }
        storage[id] = p
    }

    func prune(olderThan interval: TimeInterval, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        storage = storage.filter { now.timeIntervalSince($0.value.lastSeen) < interval }
    }

    var sorted: [Peer] {
        peers.values.sorted { a, b in
            if a.direct != b.direct { return a.direct }
            return a.lastSeen > b.lastSeen
        }
    }
}
