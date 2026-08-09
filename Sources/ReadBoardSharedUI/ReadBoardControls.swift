import SwiftUI

public struct ReadBoardQuietButtonStyle: ButtonStyle {
    public var radius: CGFloat

    public init(radius: CGFloat = ReadBoardDesign.Radius.md) {
        self.radius = radius
    }

    public func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, radius: radius)
    }

    private struct QuietButtonBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(ReadBoardDesign.C.text2)
                .padding(ReadBoardDesign.Space.xs)
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .fill(hovering || configuration.isPressed
                              ? ReadBoardDesign.C.surface : Color.clear)
                )
                .onHover { value in
                    if value != hovering { hovering = value }
                }
        }
    }
}

public struct ReadBoardRowHoverButtonStyle: ButtonStyle {
    public var radius: CGFloat

    public init(radius: CGFloat = ReadBoardDesign.Radius.md) {
        self.radius = radius
    }

    public func makeBody(configuration: Configuration) -> some View {
        RowHoverBody(configuration: configuration, radius: radius)
    }

    private struct RowHoverBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .fill(hovering || configuration.isPressed
                              ? ReadBoardDesign.C.surface.opacity(0.85) : Color.clear)
                )
                .onHover { value in
                    if value != hovering { hovering = value }
                }
        }
    }
}

public struct ReadBoardPrimaryCapsuleButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        PrimaryCapsuleBody(configuration: configuration)
    }

    private struct PrimaryCapsuleBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ReadBoardDesign.C.onAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(ReadBoardDesign.C.accent
                            .opacity(isEnabled ? (hovering ? 0.85 : 1) : 0.45))
                )
                .onHover { value in
                    if value != hovering { hovering = value }
                }
        }
    }
}

public struct ReadBoardCapsuleButton: View {
    public let title: String
    public let icon: String
    public var disabled: Bool
    public var action: () -> Void
    @State private var hovering = false

    public init(
        title: String,
        icon: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled
                    ? ReadBoardDesign.C.text3
                    : (hovering ? ReadBoardDesign.C.accent : ReadBoardDesign.C.text2))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(disabled ? ReadBoardDesign.C.surface.opacity(0.5)
                              : (hovering
                                 ? ReadBoardDesign.C.accent.opacity(0.10)
                                 : ReadBoardDesign.C.surface))
                )
                .overlay(
                    Capsule().strokeBorder(
                        hovering && !disabled
                            ? ReadBoardDesign.C.accent.opacity(0.30)
                            : ReadBoardDesign.C.hairline,
                        lineWidth: ReadBoardDesign.Line.hair)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { value in
            if value != hovering { hovering = value }
        }
    }
}

public struct ReadBoardStatusBanner<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: ReadBoardDesign.Space.sm) { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                    .fill(ReadBoardDesign.C.surface.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                    .strokeBorder(
                        ReadBoardDesign.C.hairline,
                        lineWidth: ReadBoardDesign.Line.hair)
            )
    }
}

public struct ReadBoardStaticQuietButtonStyle: ButtonStyle {
    public var radius: CGFloat

    public init(radius: CGFloat = ReadBoardDesign.Radius.md) {
        self.radius = radius
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ReadBoardDesign.C.text2)
            .padding(ReadBoardDesign.Space.xs)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(configuration.isPressed ? ReadBoardDesign.C.surface : Color.clear)
            )
    }
}

public struct ReadBoardStaticCapsuleButton: View {
    public let title: String
    public let icon: String
    public var disabled: Bool
    public var action: () -> Void

    public init(
        title: String,
        icon: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.disabled = disabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(disabled
                    ? ReadBoardDesign.C.text3 : ReadBoardDesign.C.text2)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(disabled
                        ? ReadBoardDesign.C.surface.opacity(0.5)
                        : ReadBoardDesign.C.surface)
                )
                .overlay(
                    Capsule().strokeBorder(
                        ReadBoardDesign.C.hairline,
                        lineWidth: ReadBoardDesign.Line.hair)
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

public struct ReadBoardSegmented<Item: Hashable>: View {
    public let items: [(Item, String)]
    @Binding public var selection: Item
    public var fontSize: CGFloat
    public var fillsAvailableWidth: Bool

    public init(
        items: [(Item, String)],
        selection: Binding<Item>,
        fontSize: CGFloat = 11,
        fillsAvailableWidth: Bool = false
    ) {
        self.items = items
        _selection = selection
        self.fontSize = fontSize
        self.fillsAvailableWidth = fillsAvailableWidth
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { index in
                let (item, label) = items[index]
                let active = selection == item
                Button {
                    selection = item
                } label: {
                    Text(label)
                        .font(.system(size: fontSize, weight: active ? .medium : .regular))
                        .foregroundStyle(active
                            ? ReadBoardDesign.C.accent : ReadBoardDesign.C.text2)
                        .frame(
                            maxWidth: fillsAvailableWidth ? .infinity : nil,
                            alignment: .center)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(active
                                ? ReadBoardDesign.C.accent.opacity(0.12) : Color.clear)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
            }
        }
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
        .padding(2)
        .background(Capsule().fill(ReadBoardDesign.C.surface))
        .overlay(
            Capsule().strokeBorder(
                ReadBoardDesign.C.hairline,
                lineWidth: ReadBoardDesign.Line.hair)
        )
    }
}

public struct ReadBoardRSSIcon: View {
    public var size: CGFloat
    public var color: Color

    public init(size: CGFloat = 11, color: Color = .primary) {
        self.size = size
        self.color = color
    }

    public var body: some View {
        Canvas { context, canvasSize in
            let scale = canvasSize.width / 16
            let shading = GraphicsContext.Shading.color(color)
            let dotRect = CGRect(
                x: 2 * scale,
                y: 12 * scale,
                width: 2.5 * scale,
                height: 2.5 * scale)
            context.fill(Path(ellipseIn: dotRect), with: shading)

            var innerArc = Path()
            innerArc.addArc(
                center: CGPoint(x: 2 * scale, y: 14 * scale),
                radius: 6 * scale,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false)
            context.stroke(innerArc, with: shading, lineWidth: 1.8 * scale)

            var outerArc = Path()
            outerArc.addArc(
                center: CGPoint(x: 2 * scale, y: 14 * scale),
                radius: 11 * scale,
                startAngle: .degrees(-90),
                endAngle: .degrees(0),
                clockwise: false)
            context.stroke(outerArc, with: shading, lineWidth: 1.8 * scale)
        }
        .frame(width: size, height: size)
    }
}
