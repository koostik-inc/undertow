import SwiftUI

/// A small colored dot that pulses while a tunnel is transitioning.
struct StatusDot: View {
    let status: TunnelStatus
    var size: CGFloat = 10

    var body: some View {
        ZStack {
            if status.isTransitioning {
                Circle()
                    .fill(status.color.opacity(0.35))
                    .frame(width: size * 2, height: size * 2)
                    .phaseAnimator([0.6, 1.0]) { view, scale in
                        view.scaleEffect(scale).opacity(scale == 1.0 ? 0 : 1)
                    } animation: { _ in
                        .easeOut(duration: 1.0)
                    }
            }
            Circle()
                .fill(status.color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
        .accessibilityHidden(true)
    }
}

/// Icon plus label on a status-tinted Liquid Glass capsule. Never color alone.
///
/// Reserves enough width for the longest status word ("Disconnecting") so the badge never
/// resizes — or wraps its text onto a second line — as the tunnel's status changes.
struct StatusBadge: View {
    let status: TunnelStatus

    private static let longestDisplayName = TunnelStatus.allCases.map(\.displayName).max { $0.count < $1.count }!

    var body: some View {
        ZStack(alignment: .leading) {
            Label(Self.longestDisplayName, systemImage: status.systemImage)
                .opacity(0)
                .accessibilityHidden(true)
            Label(status.displayName, systemImage: status.systemImage)
                .foregroundStyle(status.color)
                .symbolEffect(.rotate, isActive: status.isTransitioning)
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular.tint(status.color.opacity(0.25)), in: .capsule)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(TunnelStatus.allCases, id: \.self) { status in
            HStack {
                StatusDot(status: status)
                StatusBadge(status: status)
            }
        }
    }
    .padding()
    .background(AmbientBackground())
}
