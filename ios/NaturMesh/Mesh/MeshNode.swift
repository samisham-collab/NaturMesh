import Foundation
import CryptoKit

/// A message as the UI sees it, after decryption.
struct MeshMessage: Identifiable, Equatable {
    let id: MessageID
    let sender: NodeID
    let senderName: String
    let payload: Payload
    let receivedAt: Date
    let sentAt: Date
    let hops: Int
    let isMine: Bool
    /// Set on direct messages: the other end of the conversation.
    var counterpart: NodeID? = nil
    /// Decrypted text of a direct message.
    var directText: String? = nil

    var kind: MessageKind { payload.kind }
    var isUrgent: Bool { payload.isUrgent }
}

protocol MeshNodeDelegate: AnyObject {
    func meshNode(_ node: MeshNode, didReceive message: MeshMessage)
    func meshNodeDidChange(_ node: MeshNode)
}

/// Ties identity, channel, guard, transport and routing together.
///
/// Routing is controlled flooding: every node relays every accepted packet it has not seen,
/// to every neighbour except the one it came from, after a short random delay, until the hop limit.
/// Simplest thing that survives nodes appearing and vanishing.
///
/// Store and forward: accepted packets are kept for a few hours. When a new neighbour appears,
/// the store is offered to it, paced under its rate limit. If the chain broke, the message waits
/// and delivers itself when this phone walks into range of another cluster.
final class MeshNode: MeshTransportDelegate {
    let identity: Identity
    private(set) var channel: Channel
    private(set) var displayName: String
    private let transport: MeshTransport
    private let inbound = InboundGuard()
    let peers = PeerDirectory()
    private(set) var stats = TrafficStats()
    weak var delegate: MeshNodeDelegate?

    /// True when this phone has a live way out (tower, Wi-Fi with internet, satellite). Advertised in hellos.
    var isGateway = false

    private let queue = DispatchQueue(label: "org.naturmesh.node")
    private let relayJitter: ClosedRange<Double> = 0.05...0.25
    private var neighbours: Set<String> = []
    private(set) var connectedNeighbourCount = 0
    private var stopped = true

    // Carry store
    private struct Carried { let id: MessageID; let data: Data; let storedAt: Date; let priority: Int }
    private var carried: [Carried] = []
    private let carryLimit = 400
    private let carryMaxAge: TimeInterval = 6 * 60 * 60
    private let publicChannel = Channel(passphrase: Channel.defaultName)

    init(identity: Identity, channel: Channel, displayName: String, transport: MeshTransport? = nil) {
        self.identity = identity
        self.channel = channel
        self.displayName = displayName
        self.transport = transport ?? MultipeerTransport(displayName: displayName)
        self.transport.delegate = self
    }

    func start() {
        stopped = false
        transport.start()
    }

    func stop() {
        stopped = true
        transport.stop()
        queue.async { self.neighbours.removeAll(); self.connectedNeighbourCount = 0; self.notifyChange() }
    }

    func setChannel(_ c: Channel) { queue.async { self.channel = c } }
    func setDisplayName(_ n: String) { queue.async { self.displayName = String(n.prefix(Wire.maxNameBytes)) } }

    // MARK: Sending

    /// Broadcast on the current channel.
    @discardableResult
    func send(_ payload: Payload, hopLimit: UInt8 = Wire.defaultHopLimit) -> MeshMessage? {
        queue.sync { buildAndSend(payload, hopLimit: hopLimit, on: channel) }
    }

    /// Tell the mesh who we are. Carries the key-agreement key others need to message us directly.
    func sendHello(battery: UInt8) {
        queue.async {
            _ = self.buildAndSend(.hello(name: self.displayName, agreementKey: self.identity.agreementPublicKeyData,
                                         battery: battery, gateway: self.isGateway),
                                  hopLimit: Wire.defaultHopLimit, on: self.channel, carry: false)
        }
    }

    /// End-to-end encrypted to one node. The outer layer rides the public channel so any phone can relay it;
    /// the inner box opens only with the pair key.
    enum DirectError: Error { case noKey, tooLong, sealFailed }

    func sendDirect(_ text: String, to peer: Peer, hopLimit: UInt8 = Wire.maxHopLimit) throws -> MeshMessage {
        guard let theirKey = peer.agreementKey, let key = identity.pairKey(with: theirKey) else { throw DirectError.noKey }
        var w = ByteWriter(); w.string(text, max: 240)
        guard let box = DirectBox.seal(w.data, key: key) else { throw DirectError.sealFailed }
        let payload = Payload.direct(to: peer.id, box: box)
        guard payload.encode().count <= Wire.maxBodyBytes else { throw DirectError.tooLong }
        guard var m = queue.sync(execute: { buildAndSend(payload, hopLimit: hopLimit, on: publicChannel) }) else { throw DirectError.tooLong }
        m.counterpart = peer.id
        m.directText = text
        return m
    }

    private func buildAndSend(_ payload: Payload, hopLimit: UInt8, on ch: Channel, carry: Bool = true) -> MeshMessage? {
        let body = payload.encode()
        guard body.count <= Wire.maxBodyBytes else { return nil }
        let id = MessageID.random()
        let nonce = Channel.randomNonce()
        let ts = UInt64(Date().timeIntervalSince1970 * 1000)
        let limit = min(max(hopLimit, 1), Wire.maxHopLimit)
        let flags: UInt8 = payload.isUrgent && payload.kind == .text ? PacketFlags.urgent : 0
        var packet = Packet(kind: payload.kind, flags: flags, hopLimit: limit, hopCount: 0, channelTag: ch.tag,
                            id: id, senderPublicKey: identity.publicKeyData, timestampMillis: ts, nonce: nonce,
                            ciphertext: Data(), signature: Data())
        guard let sealed = try? ch.seal(body, nonce: nonce, aad: packet.aad) else { return nil }
        packet.ciphertext = sealed
        guard let sig = try? identity.sign(packet.signedBytes) else { return nil }
        packet.signature = sig

        let data = packet.encode()
        inbound.remember(id)
        stats.sent += 1
        transport.send(data, to: nil)
        if carry {
            var next = packet; next.hopCount = 1
            store(Carried(id: id, data: next.encode(), storedAt: Date(), priority: payload.kind.priority))
        }
        notifyChange()
        return MeshMessage(id: id, sender: identity.nodeID, senderName: displayName, payload: payload,
                           receivedAt: Date(), sentAt: Date(), hops: 0, isMine: true)
    }

    // MARK: Transport delegate

    func transport(_ t: MeshTransport, received data: Data, from neighbour: String) {
        queue.async { self.handle(data, from: neighbour) }
    }

    func transport(_ t: MeshTransport, neighbourChanged neighbour: String, connected: Bool) {
        queue.async {
            if connected {
                self.neighbours.insert(neighbour)
                self.offerCarried(to: neighbour)
            } else {
                self.neighbours.remove(neighbour)
                self.inbound.forget(neighbour: neighbour)
            }
            self.connectedNeighbourCount = self.neighbours.count
            self.notifyChange()
        }
    }

    // MARK: Inbound

    private func handle(_ data: Data, from neighbour: String) {
        switch inbound.inspect(data, fromNeighbour: neighbour) {
        case .drop(let reason):
            stats.dropped[reason, default: 0] += 1
            notifyChange()

        case .accept(var packet):
            stats.received += 1
            let payload = open(packet)
            peers.observe(packet, payload: payload, now: Date())
            if let payload { deliver(payload, from: packet) }

            // Relay
            let others = neighbours.subtracting([neighbour])
            if packet.hopCount < packet.hopLimit {
                packet.hopCount += 1
                let out = packet.encode()
                store(Carried(id: packet.id, data: out, storedAt: Date(), priority: packet.kind.priority))
                if !others.isEmpty {
                    let delay = Double.random(in: relayJitter) * (packet.kind == .sos ? 0.5 : 1)
                    queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, !self.stopped else { return }
                        self.transport.send(out, to: Array(others))
                        self.stats.relayed += 1
                        self.notifyChange()
                    }
                }
            } else {
                stats.dropped[.hopLimit, default: 0] += 1
            }
            notifyChange()
        }
    }

    /// Only messages on our channel (or direct messages on the public channel) are readable; everything else is relayed opaque.
    private func open(_ packet: Packet) -> Payload? {
        let ch: Channel
        if packet.kind == .direct { ch = publicChannel }
        else if packet.channelTag == channel.tag { ch = channel }
        else { return nil }
        guard ch.tag == packet.channelTag,
              let plain = ch.open(packet.ciphertext, nonce: packet.nonce, aad: packet.aad) else { return nil }
        guard var payload = try? Payload.decode(kind: packet.kind, plain) else { return nil }
        if case .text(let s, _) = payload { payload = .text(s, urgent: packet.flags & PacketFlags.urgent != 0) }
        return payload
    }

    private func deliver(_ payload: Payload, from packet: Packet) {
        let name: String
        switch payload {
        case .position(_, _, let n), .sos(_, _, let n, _), .checkIn(_, _, _, let n), .gatewayAdvert(let n), .hello(let n, _, _, _): name = n
        default: name = peers.peers[packet.sender]?.name ?? ""
        }
        var msg = MeshMessage(id: packet.id, sender: packet.sender, senderName: name, payload: payload,
                              receivedAt: Date(), sentAt: packet.timestamp, hops: Int(packet.hopCount), isMine: false)
        if case .direct(let to, let box) = payload {
            guard to == identity.nodeID,
                  let theirKey = peers.peers[packet.sender]?.agreementKey,
                  let key = identity.pairKey(with: theirKey),
                  let plain = DirectBox.open(box, key: key) else { return } // not for us, or no hello from them yet
            var r = ByteReader(plain)
            guard let text = try? r.string() else { return }
            msg.counterpart = packet.sender
            msg.directText = text
        }
        DispatchQueue.main.async { self.delegate?.meshNode(self, didReceive: msg) }
    }

    // MARK: Carry store

    private func store(_ c: Carried) {
        let now = Date()
        carried.removeAll { now.timeIntervalSince($0.storedAt) > carryMaxAge || $0.id == c.id }
        carried.append(c)
        if carried.count > carryLimit {
            // Drop the oldest low-priority entries first.
            carried.sort { a, b in a.priority != b.priority ? a.priority > b.priority : a.storedAt > b.storedAt }
            carried.removeLast(carried.count - carryLimit)
        }
    }

    /// Hand a new neighbour everything we are carrying, highest priority first, well under its 20/s bucket.
    private func offerCarried(to neighbour: String) {
        let now = Date()
        carried.removeAll { now.timeIntervalSince($0.storedAt) > carryMaxAge }
        let batch = carried.sorted { a, b in a.priority != b.priority ? a.priority > b.priority : a.storedAt < b.storedAt }
        guard !batch.isEmpty else { return }
        for (i, c) in batch.enumerated() {
            queue.asyncAfter(deadline: .now() + 1.0 + Double(i) * 0.12) { [weak self] in
                guard let self, !self.stopped, self.neighbours.contains(neighbour) else { return }
                self.transport.send(c.data, to: [neighbour])
            }
        }
        stats.relayed += batch.count
    }

    var carriedCount: Int { queue.sync { carried.count } }

    private func notifyChange() {
        DispatchQueue.main.async { self.delegate?.meshNodeDidChange(self) }
    }
}
