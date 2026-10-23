import SwiftUI

/// Soft color washes behind content so Liquid Glass surfaces have something to refract.
struct AmbientBackground: View {
    var tint: Color = .indigo
    var secondaryTint: Color = .teal

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            Circle()
                .fill(tint.opacity(0.30))
                .frame(width: 560, height: 560)
                .blur(radius: 130)
                .offset(x: -240, y: -280)
            Circle()
                .fill(secondaryTint.opacity(0.22))
                .frame(width: 520, height: 520)
                .blur(radius: 130)
                .offset(x: 280, y: 240)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// A compact headline number with a caption on a Liquid Glass tile.
struct StatTile<Value: View>: View {
    let title: String
    let systemImage: String
    var tint: Color = .secondary
    @ViewBuilder let value: () -> Value

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .symbolRenderingMode(.hierarchical)
                .imageScale(.small)
                .tint(tint)
            value()
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

extension StatTile where Value == Text {
    init(title: String, systemImage: String, tint: Color = .secondary, text: String) {
        self.init(title: title, systemImage: systemImage, tint: tint) { Text(text) }
    }
}

/// A Liquid Glass card with a title row, for sections of a detail screen.
struct Card<Content: View, Accessory: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory

    init(_ title: String,
         systemImage: String? = nil,
         @ViewBuilder content: @escaping () -> Content,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if let systemImage {
                    Label(title, systemImage: systemImage)
                        .font(.headline)
                } else {
                    Text(title).font(.headline)
                }
                Spacer()
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// A small glass capsule tag, e.g. “Full tunnel” or “On demand”.
struct TagPill: View {
    let title: String
    var systemImage: String?

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(.regular, in: .capsule)
    }
}
