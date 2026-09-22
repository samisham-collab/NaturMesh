import Foundation
import SwiftUI
import Combine

/// Single source of truth for the UI. Owns the mesh node and mirrors its state on the main thread.
@MainActor
final class AppModel: ObservableObject, MeshNodeDelegate {
    private let defaults = UserDefaults.standard

    @Published var displayName: String {
        didSet { defaults.set(displayName, forKey: "displayName"); node.setDisplayName(myName); sayHello() }
    }
    @Published var channelPassphrase: String {
        didSet { defaults.set(channelPassphrase, forKey: "channelPassphrase"); applyChannel() }
    }
    /// Saved group channels: a shelter roster, a road-clearing crew. Switch with one tap.
    @Published var savedChannels: [String] {
        didSet { defaults.set(savedChannels, forKey: "savedChannels") }
    }
    @Published var sharePosition: Bool {
        didSet { defaults.set(sharePosition, forKey: "sharePosition"); schedulePositionShare() }
    }
    @Published var hopLimit: Int {
        didSet { defaults.set(hopLimit, forKey: "hopLimit") }
    }
    /// Battery saver: stop relaying while this phone still has service. Off by default; responders want the mesh up.
    @Published var pauseWhileServiceUp: Bool {
        didSet { defaults.set(pauseWhileServiceUp, forKey: "pauseWhileServiceUp"); reconcileRunning() }
    }

    @Published private(set) var messages: [MeshMessage] = []
    @Published private(set) var peers: [Peer] = []
    @Published private(set) var stats = TrafficStats()
    @Published private(set) var neighbourCount = 0
    @Published private(set) var carriedCount = 0
    @Published private(set) var channelName = Channel.defaultName
    @Published var activeSOS: MeshMessage?
    @Published private(set) var running = false

    let location = LocationService()
    let uplink = UplinkMonitor()
    let identity: Identity
    private var node: MeshNode
    private var positionTimer: Timer?
    private var helloTimer: Timer?
    private var pruneTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    var nodeID: NodeID { identity.nodeID }
    var myName: String { displayName.isEmpty ? "Node " + nodeID.short : displayName }
    var isGateway: Bool { uplink.hasInternet }
    var gatewayCount: Int { peers.filter(\.isGateway).count + (isGateway ? 1 : 0) }
    var urgentMessages: [MeshMessage] { messages.filter { $0.isUrgent && !$0.isMine && Date().timeIntervalSince($0.receivedAt) < 3600 } }

    init() {
        let identity = Identity.loadOrCreate()
        self.identity = identity
        let d = UserDefaults.standard
        let stored = d.string(forKey: "channelPassphrase") ?? ""
        let name = d.string(forKey: "displayName") ?? ""
        displayName = name
        channelPassphrase = stored
        savedChannels = d.stringArray(forKey: "savedChannels") ?? []
        sharePosition = d.bool(forKey: "sharePosition")
        pauseWhileServiceUp = d.bool(forKey: "pauseWhileServiceUp")
        let storedHops = d.integer(forKey: "hopLimit")
        hopLimit = (1...Int(Wire.maxHopLimit)).contains(storedHops) ? storedHops : Int(Wire.defaultHopLimit)
        let channel = Channel(passphrase: stored)
        node = MeshNode(identity: identity, channel: channel, displayName: name.isEmpty ? "Node " + identity.nodeID.short : name)
        channelName = channel.name
        node.delegate = self

        uplink.$hasInternet
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] has in
                guard let self else { return }
                self.node.isGateway = has
                self.reconcileRunning()
                if self.running { self.sayHello() }
                self.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Nested observable objects don't bubble up on their own.
        uplink.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        location.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
    }

    // MARK: Lifecycle

    func start() {
        uplink.start()
        reconcileRunning()
    }

    private func reconcileRunning() {
        let shouldRun = !(pauseWhileServiceUp && uplink.hasInternet)
        if shouldRun && !running { startMesh() }
        if !shouldRun && running { stopMesh() }
    }

    private func startMesh() {
        running = true
        node.start()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPeers() }
        }
        helloTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sayHello() }
        }
        sayHello()
        schedulePositionShare()
    }

    private func stopMesh() {
        running = false
        node.stop()
        pruneTimer?.invalidate(); positionTimer?.invalidate(); helloTimer?.invalidate()
        neighbourCount = 0
    }

    // MARK: Actions

    func sendText(_ text: String, urgent: Bool = false) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let m = node.send(.text(t, urgent: urgent), hopLimit: UInt8(hopLimit)) { messages.append(m) }
    }

    func sendDirect(_ text: String, to peer: Peer) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        guard let m = try? node.sendDirect(t, to: peer) else { return false }
        messages.append(m)
        return true
    }

    func directThread(with peer: Peer) -> [MeshMessage] {
        messages.filter { $0.counterpart == peer.id }
    }

    func sendSOS(note: String = "") {
        let payload = Payload.sos(location.current, battery: Battery.level(), name: myName, note: note)
        if let m = node.send(payload, hopLimit: Wire.maxHopLimit) { messages.append(m); activeSOS = m }
    }

    func cancelSOS() {
        activeSOS = nil
        sendCheckIn(.ok)
    }

    func sendCheckIn(_ status: CheckInStatus) {
        let payload = Payload.checkIn(status, location.current, battery: Battery.level(), name: myName)
        if let m = node.send(payload, hopLimit: UInt8(hopLimit)) { messages.append(m) }
    }

    func sharePositionNow() {
        guard let p = location.current else { return }
        node.send(.position(p, battery: Battery.level(), name: myName), hopLimit: UInt8(hopLimit))
    }

    func sayHello() {
        guard running else { return }
        node.sendHello(battery: Battery.level())
    }

    func switchChannel(_ passphrase: String) {
        channelPassphrase = passphrase
    }

    func saveCurrentChannel() {
        let p = channelPassphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, !savedChannels.contains(p) else { return }
        savedChannels.append(p)
    }

    func removeSavedChannel(_ p: String) {
        savedChannels.removeAll { $0 == p }
    }

    // MARK: Internals

    private func applyChannel() {
        let c = Channel(passphrase: channelPassphrase)
        channelName = c.name
        node.setChannel(c)
        messages.removeAll { $0.counterpart == nil }
        sayHello()
    }

    private func schedulePositionShare() {
        positionTimer?.invalidate()
        guard sharePosition, running else { return }
        location.start()
        sharePositionNow()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sharePositionNow() }
        }
    }

    private func refreshPeers() {
        node.peers.prune(olderThan: 30 * 60)
        peers = node.peers.sorted
        carriedCount = node.carriedCount
    }

    // MARK: MeshNodeDelegate (called on main)

    nonisolated func meshNode(_ node: MeshNode, didReceive message: MeshMessage) {
        Task { @MainActor in
            switch message.payload {
            case .ack, .gatewayAdvert, .hello: break
            case .direct: if message.directText != nil { self.messages.append(message) }
            default: self.messages.append(message)
            }
            if self.messages.count > 500 { self.messages.removeFirst(self.messages.count - 500) }
            self.refreshPeers()
        }
    }

    nonisolated func meshNodeDidChange(_ node: MeshNode) {
        Task { @MainActor in
            self.stats = node.stats
            self.neighbourCount = node.connectedNeighbourCount
            self.refreshPeers()
        }
    }
}
