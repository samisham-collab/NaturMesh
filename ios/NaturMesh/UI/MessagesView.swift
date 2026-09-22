import SwiftUI

struct MessagesView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ""
    @State private var urgent = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                LinkStatus().padding(.horizontal).padding(.vertical, 8)
                Rectangle().fill(Brand.rule).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            if model.messages.isEmpty { emptyState }
                            ForEach(model.messages.filter { $0.counterpart == nil }) { m in
                                MessageRow(message: m).id(m.id)
                                Rectangle().fill(Brand.rule).frame(height: 1)
                            }
                        }
                    }
                    .onChange(of: model.messages.count) { _, _ in
                        if let last = model.messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
                CheckInBar()
                composer
            }
            .background(Brand.canopy)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { BrandHeader() }
                ToolbarItem(placement: .principal) { Text(model.channelName).font(Brand.mono(12)).foregroundStyle(Brand.lichen) }
                ToolbarItem(placement: .topBarTrailing) { SOSButton() }
            }
            .toolbarBackground(Brand.canopy, for: .navigationBar)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            LeafMark(size: 44).padding(.bottom, 4)
            Text("Your neighbours are\nthe infrastructure.")
                .font(Brand.display(24)).foregroundStyle(Brand.birch).multilineTextAlignment(.center)
            Text("Anything sent here hops phone to phone until it reaches everyone on the \(model.channelName) channel. No tower, no server, no account.")
                .font(Brand.text(14)).foregroundStyle(Brand.lichen).multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .padding(.vertical, 48).padding(.horizontal)
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Message everyone", text: $draft, axis: .vertical)
                .font(Brand.text(16))
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Brand.bark, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(urgent ? Brand.ember : Brand.rule, lineWidth: 1))
                .focused($focused)
                .onSubmit(send)
            Button { urgent.toggle() } label: {
                Text("!").font(Brand.text(19, weight: .bold))
                    .frame(width: 42, height: 42)
                    .background(urgent ? Brand.ember : Brand.bark, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(urgent ? Brand.birch : Brand.lichen)
            }
            .accessibilityLabel(urgent ? "Urgent, on" : "Mark urgent")
            Button(action: send) {
                Text("Send").font(Brand.text(15, weight: .semibold))
                    .padding(.horizontal, 14).frame(height: 42)
                    .background(Brand.signal, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .foregroundStyle(Brand.moss)
            }
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Brand.canopy)
        .overlay(alignment: .top) { Rectangle().fill(Brand.rule).frame(height: 1) }
    }

    private func send() {
        model.sendText(draft, urgent: urgent)
        draft = ""
        urgent = false
    }
}

/// Log entries, as in the site's prototype: name, time, an urgent flag that cuts through, then the body.
struct MessageRow: View {
    let message: MeshMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(message.isMine ? "You" : (message.senderName.isEmpty ? "Node " + message.sender.short : message.senderName))
                    .font(Brand.text(13, weight: .semibold))
                    .foregroundStyle(message.isMine ? Brand.signal : Brand.lichen)
                Text(message.sentAt, style: .time).font(Brand.mono(12)).foregroundStyle(Brand.lichen.opacity(0.8))
                if !message.isMine {
                    Text(message.hops == 0 ? "direct" : "\(message.hops) hop\(message.hops == 1 ? "" : "s")")
                        .font(Brand.mono(11)).foregroundStyle(Brand.lichen.opacity(0.6))
                }
                if message.isUrgent && message.kind == .text {
                    Text("urgent").font(Brand.text(11, weight: .semibold)).foregroundStyle(Brand.ember)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Brand.ember, lineWidth: 1))
                }
                Spacer()
            }
            content
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.isMine ? Brand.bark : Brand.canopy)
        .overlay(alignment: .leading) {
            if message.isUrgent { Rectangle().fill(Brand.ember).frame(width: 3) }
        }
    }

    @ViewBuilder private var content: some View {
        switch message.payload {
        case .text(let t, _):
            Text(t).font(Brand.text(16)).foregroundStyle(Brand.birch)
        case .sos(let geo, let battery, _, let note):
            Label("SOS", systemImage: "light.beacon.max.fill").font(Brand.text(16, weight: .bold)).foregroundStyle(Brand.ember)
            if !note.isEmpty { Text(note).font(Brand.text(16)).foregroundStyle(Brand.birch) }
            meta(geo: geo, battery: battery)
        case .checkIn(let status, let geo, let battery, _):
            Label(status.label, systemImage: status.symbol).font(Brand.text(15, weight: .medium))
                .foregroundStyle(status == .needHelp ? Brand.ember : Brand.signal)
            meta(geo: geo, battery: battery)
        case .position(let geo, let battery, _):
            Label("Shared position", systemImage: "location.fill").font(Brand.text(15)).foregroundStyle(Brand.lichen)
            meta(geo: geo, battery: battery)
        case .direct:
            Text(message.directText ?? "").font(Brand.text(16)).foregroundStyle(Brand.birch)
        case .ack, .gatewayAdvert, .hello:
            EmptyView()
        }
    }

    @ViewBuilder private func meta(geo: GeoPoint?, battery: UInt8) -> some View {
        HStack(spacing: 10) {
            if let geo { Text(String(format: "%.5f, %.5f ±%dm", geo.latitude, geo.longitude, Int(geo.accuracyMeters))) }
            if battery != 255 { Label("\(battery)%", systemImage: "battery.50percent") }
        }
        .font(Brand.mono(12)).foregroundStyle(Brand.lichen)
    }
}
