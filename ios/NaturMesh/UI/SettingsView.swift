import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var newChannel = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Display name", text: $model.displayName).textInputAutocapitalization(.words)
                    LabeledContent("Node ID", value: model.nodeID.short)
                } header: { header("You") } footer: {
                    footer("A call sign, a room number, or just your first name. No account, no phone number, no email.")
                }

                Section {
                    SecureField("Channel passphrase", text: $model.channelPassphrase)
                    LabeledContent("Active channel", value: model.channelName)
                    if !model.channelPassphrase.isEmpty && !model.savedChannels.contains(model.channelPassphrase) {
                        Button("Save this channel") { model.saveCurrentChannel() }
                    }
                    ForEach(model.savedChannels, id: \.self) { c in
                        Button {
                            model.switchChannel(c)
                        } label: {
                            HStack {
                                Text(Channel(passphrase: c).name)
                                Spacer()
                                if c == model.channelPassphrase { Image(systemName: "checkmark").foregroundStyle(Brand.signal) }
                            }
                        }
                    }
                    .onDelete { idx in idx.map { model.savedChannels[$0] }.forEach(model.removeSavedChannel) }
                    if !model.channelPassphrase.isEmpty {
                        Button("Back to public") { model.switchChannel("") }.foregroundStyle(Brand.lichen)
                    }
                } header: { header("Group channels") } footer: {
                    footer("A shelter roster, a road-clearing crew. Phones with the same passphrase can read each other; everyone else still relays for you. Blank is the public channel.")
                }

                Section {
                    Toggle("Share my position every 5 min", isOn: $model.sharePosition)
                    Stepper("Hop limit: \(model.hopLimit)", value: $model.hopLimit, in: 1...Int(Wire.maxHopLimit))
                    Toggle("Pause relaying while I still have service", isOn: $model.pauseWhileServiceUp)
                    LabeledContent("Carrying for others", value: "\(model.carriedCount) message\(model.carriedCount == 1 ? "" : "s")")
                } header: { header("Mesh") } footer: {
                    footer("Each hop is one more phone. Messages retire after 7 hops; SOS always uses the maximum. Carried messages wait up to 6 hours and deliver themselves when you meet another cluster.")
                }

                Section {
                    LabeledContent("Interface", value: model.uplink.interfaceName)
                    LabeledContent("Internet", value: model.uplink.hasInternet ? "yes · advertising as gateway" : "no")
                } header: { header("Way out") } footer: {
                    footer("The first phone in the chain with a working tower, satellite link or live Wi-Fi becomes everyone's gateway. A surviving access point with no internet behind it still bridges clusters: naturMesh joins it like any Wi-Fi and meshes across it.")
                }

                Section { StatsView(stats: model.stats) } header: { header("Traffic") }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
                    LabeledContent("Price", value: "Free. Actually free.")
                    Text("Text, position, SOS, check-ins and direct messages only. Photos, audio and video cannot enter the mesh. Every message is signed (Ed25519); direct messages are end-to-end encrypted (X25519).")
                        .font(Brand.text(13)).foregroundStyle(Brand.lichen)
                } header: { header("About") }
            }
            .font(Brand.text(16))
            .scrollContentBackground(.hidden)
            .background(Brand.canopy)
            .navigationTitle("Settings")
        }
    }

    private func header(_ s: String) -> some View { Text(s).font(Brand.text(12, weight: .semibold)).foregroundStyle(Brand.lichen) }
    private func footer(_ s: String) -> some View { Text(s).font(Brand.text(12)).foregroundStyle(Brand.lichen) }
}

struct StatsView: View {
    let stats: TrafficStats

    var body: some View {
        LabeledContent("Sent", value: "\(stats.sent)")
        LabeledContent("Received", value: "\(stats.received)")
        LabeledContent("Relayed", value: "\(stats.relayed)")
        LabeledContent("Dropped", value: "\(stats.totalDropped)")
        ForEach(DropReason.allCases.filter { (stats.dropped[$0] ?? 0) > 0 }) { r in
            LabeledContent(r.rawValue, value: "\(stats.dropped[r] ?? 0)")
                .font(Brand.text(13)).foregroundStyle(Brand.lichen)
        }
    }
}
