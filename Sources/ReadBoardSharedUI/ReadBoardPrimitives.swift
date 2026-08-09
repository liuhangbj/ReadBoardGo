import SwiftUI

/// Core 复制基线中的 0.5pt 横向分割线。
public struct ReadBoardHairline: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(ReadBoardDesign.C.hairline)
            .frame(height: ReadBoardDesign.Line.hair)
    }
}

/// Core 复制基线中的垂直分割线。
public struct ReadBoardVHairline: View {
    public var height: CGFloat

    public init(height: CGFloat = 14) {
        self.height = height
    }

    public var body: some View {
        Rectangle()
            .fill(ReadBoardDesign.C.hairline)
            .frame(width: ReadBoardDesign.Line.hair, height: height)
    }
}

/// Core 复制基线中的眉题小标题。
public struct ReadBoardSectionLabel: View {
    public let text: String

    public init(text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(.system(size: ReadBoardDesign.F.section, weight: .medium))
            .foregroundStyle(ReadBoardDesign.C.text3)
            .tracking(ReadBoardDesign.Track.section)
    }
}

/// Core 复制基线中的评分和处理状态标签。
public struct ReadBoardBadge: View {
    public let text: String
    public let color: Color
    public var scale: Double

    public init(text: String, color: Color, scale: Double = 1) {
        self.text = text
        self.color = color
        self.scale = scale
    }

    public var body: some View {
        Text(text)
            .font(.system(size: ReadBoardDesign.F.badge * scale, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.sm)
                    .strokeBorder(color.opacity(0.22), lineWidth: ReadBoardDesign.Line.hair)
            )
    }
}
