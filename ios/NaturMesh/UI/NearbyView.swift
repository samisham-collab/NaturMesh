import SwiftUI

struct NearbyView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Peer?

    var body: some View {
        NavigationStack {
            List {
                Section { LinkStatus().listRowBackground(Brand.canopy) }
                if model.peers.isEmpty {
                    Section {
                        VStack(spacing: 8) {
                            Text("Nothing out here\nis on the grid.").font(Brand.display(22)).foregroundStyle(Brand.birch).multilineTextAlignment(.center)
                            Text("Phones running naturMesh within Bluetooth or Wi-Fi range join on their own. Nobody needs to know you to help you.")
                                .font(Brand.text(14)).foregroundStyle(Brand.lichen).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 24)
                        .listRowBackground(Brand.canopy)
                    }
                } else {
                    Section {
                        ForEach(model.peers) { p in
                            Button { selected = p } label: {
                                PeerRow(peer: p, me: model.location.current, heading: model.location.heading)
                            }
                            .listRowBackground(Brand.bark)
                        }
                    } header: {
                        Text("On the mesh").font(Brand.text(12, weight: .semibold)).foregroundStyle(Brand.lichen)
                    } footer: {
                        Text("Tap someone to message them directly. Direct messages are end-to-end encrypted (X25519); relays carry them without reading them.")
                            .font(Brand.text(12)).foregroundStyle(Brand.lichen)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Brand.canopy)
            .navigationTitle("Nearby")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { SOSButton() } }
            .sheet(item: $selected) { p in DirectMessageView(peer: p) }
        }
    }
}

struct PeerRow: View {
    let peer: Peer
    let me: GeoPoint?
    let heading: Double?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(peer.displayName).font(Brand.text(16, weight: .medium)).foregroundStyle(Brand.birch)
                    if peer.isGateway {
                        Text("gateway").font(Brand.text(11, weight: .semibold)).foregroundStyle(Brand.moss)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Brand.signal, in: RoundedRectangle(cornerRadius: 3))
                    }
                    if let s = peer.lastStatus {
                        Image(systemName: s.symbol).foregroundStyle(s == .needHelp ? Brand.ember : Brand.signal).font(.footnote)
                    }
                }
                HStack(spacing: 6) {
                    Text(peer.direct ? "direct" : "\(peer.hops) hop\(peer.hops == 1 ? "" : "s")")
                    Text("·")
                    Text("seen \(peer.lastSeen, style: .relative) ago")
                    if let b = peer.battery, b != 255 { Text("·"); Text("\(b)%") }
                }
                .font(Brand.mono(12)).foregroundStyle(Brand.lichen)
            }
            Spacer()
            if let me, let pos = peer.position {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(GeoPoint.format(distanceMeters: me.distance(to: pos))).font(Brand.mono(14)).foregroundStyle(Brand.birch)
                    Image(systemName: "location.north.fill")
                        .rotationEffect(.degrees(me.bearing(to: pos) - (heading ?? 0)))
                        .foregroundStyle(Brand.signal)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Brand.lichen.opacity(0.6))
        }
        .padding(.vertical, 2)
    }
}

/// One-to-one thread. Needs the other side's hello (which carries their key) before the first message can be sealed.
struct DirectMessageView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let peer: Peer
    @State private var draft = ""
    @State private var failed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let thread = model.directThread(with: peer)
                        if thread.isEmpty {
                            Text("End-to-end encrypted. Only \(peer.displayName) can read this; everyone in between just carries it.")
                                .font(Brand.text(13)).foregroundStyle(Brand.lichen).multilineTextAlignment(.center)
                                .padding(24)
                        }
                        ForEach(thread) { m in
                            MessageRow(message: m)
                            Rectangle().fill(Brand.rule).frame(height: 1)
                        }
                    }
                }
                if peer.agreementKey == nil {
                    Text("Waiting for \(peer.displayName)'s key. It arrives with their next hello (every 5 minutes, or when they change channel).")
                        .font(Brand.text(12)).foregroundStyle(Brand.ember).padding(.horizontal).padding(.bottom, 6)
                }
                HStack(spacing: 8) {
                    TextField("Message \(peer.displayName)", text: $draft, axis: .vertical)
                        .font(Brand.text(16)).lineLimit(1...4).textFieldStyle(.plain)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Brand.bark, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .onSubmit(send)
                    Button(action: send) {
                        Text("Send").font(Brand.text(15, weight: .semibold))
                            .padding(.horizontal, 14).frame(height: 42)
                            .background(Brand.signal, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .foregroundStyle(Brand.moss)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || peer.agreementKey == nil)
                    .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty || peer.agreementKey == nil ? 0.4 : 1)
                }
                .padding(14)
            }
            .background(Brand.canopy)
            .navigationTitle(peer.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.font(Brand.text(15, weight: .semibold)) } }
            .alert("Couldn't seal that message", isPresented: $failed) { Button("OK") {} } message: {
                Text("Either the message is too long for one packet (240 characters) or the key is missing.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func send() {
        if model.sendDirect(draft, to: peer) { draft = "" } else { failed = true }
    }
}
