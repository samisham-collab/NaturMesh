import SwiftUI

/// Hold for two seconds. A stray tap should not page a whole county.
struct SOSButton: View {
    @EnvironmentObject var model: AppModel
    @State private var progress: Double = 0
    @State private var holding = false
    @State private var timer: Timer?

    private let holdSeconds = 2.0

    var body: some View {
        ZStack {
            Circle().stroke(Brand.ember.opacity(0.3), lineWidth: 3)
            Circle().trim(from: 0, to: progress).stroke(Brand.ember, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("SOS").font(Brand.text(11, weight: .bold)).foregroundStyle(Brand.ember)
        }
        .frame(width: 40, height: 40)
        .scaleEffect(holding ? 1.12 : 1)
        .animation(.easeOut(duration: 0.15), value: holding)
        .contentShape(Circle())
        .onLongPressGesture(minimumDuration: holdSeconds, maximumDistance: 30, perform: fire, onPressingChanged: pressing)
        .accessibilityLabel("Send SOS, hold for two seconds")
    }

    private func pressing(_ down: Bool) {
        holding = down
        timer?.invalidate()
        if down {
            progress = 0
            let start = Date()
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { t in
                progress = min(1, Date().timeIntervalSince(start) / holdSeconds)
                if progress >= 1 { t.invalidate() }
            }
        } else {
            withAnimation { progress = 0 }
        }
    }

    private func fire() {
        timer?.invalidate()
        holding = false
        progress = 0
        model.location.start()
        model.sendSOS()
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}
