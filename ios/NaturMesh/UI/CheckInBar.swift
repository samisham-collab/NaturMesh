import SwiftUI

/// Most emergency traffic is status, not prose. One tap each.
struct CheckInBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(CheckInStatus.allCases) { s in
                Button {
                    model.sendCheckIn(s)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Label(s.label, systemImage: s.symbol)
                        .font(Brand.text(13, weight: .medium))
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Brand.bark, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Brand.rule, lineWidth: 1))
                        .foregroundStyle(s == .needHelp ? Brand.ember : Brand.signal)
                }
            }
        }
        .padding(.horizontal, 14).padding(.top, 8)
        .background(Brand.canopy)
    }
}
