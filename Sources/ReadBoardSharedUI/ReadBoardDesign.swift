import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Core 复制基线提取出的唯一视觉常量层。
///
/// 数值和颜色必须与复制基线保持一致；共享化只改变代码归属，不改变界面结果。
public enum ReadBoardDesign {
    public static func dynamic(_ light: String, _ dark: String) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(readBoardHex: isDark ? dark : light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(readBoardHex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }

    public enum C {
        public static let bg = ReadBoardDesign.dynamic("#FFFFFF", "#1D1C1A")
        public static let bgSidebar = ReadBoardDesign.dynamic("#F7F6F2", "#161514")
        public static let surface = ReadBoardDesign.dynamic("#F5F4F0", "#282622")
        public static let text = ReadBoardDesign.dynamic("#282622", "#E5E2DA")
        public static let text2 = ReadBoardDesign.dynamic("#6F6A5E", "#A19C90")
        public static let text3 = ReadBoardDesign.dynamic("#AAA498", "#65615A")
        public static let accent = ReadBoardDesign.dynamic("#2F5B8F", "#7AA4D9")
        public static let onAccent = ReadBoardDesign.dynamic("#FFFFFF", "#1D1C1A")
        public static let hairline = ReadBoardDesign.dynamic("#EBE9E3", "#35322C")
        public static let separator = ReadBoardDesign.dynamic("#DDDAD1", "#45413A")
        public static let scoreHigh = ReadBoardDesign.dynamic("#4C8A5A", "#7BAF86")
        public static let scoreGood = accent
        public static let scoreMid = ReadBoardDesign.dynamic("#B07A3A", "#CE9E5F")
        public static let scoreLow = ReadBoardDesign.dynamic("#B0524A", "#CE7B74")
        public static let scoreNone = ReadBoardDesign.dynamic("#9BA1AB", "#5C6270")
        public static let star = ReadBoardDesign.dynamic("#C9A24B", "#D9BC6E")
        public static let summary = ReadBoardDesign.dynamic("#7A6AA0", "#9E8FC0")
        public static let translate = ReadBoardDesign.dynamic("#4A7A8C", "#6FA3B3")
        public static let rss = ReadBoardDesign.dynamic("#E66A22", "#F08A4B")
        public static let podcast = ReadBoardDesign.dynamic("#8B4CB8", "#B07AD3")
        public static let video = ReadBoardDesign.dynamic("#D95A56", "#E98480")
        public static let youtube = video
        public static let bilibili = ReadBoardDesign.dynamic("#4FA9C4", "#79C5D8")
        public static let wechat = ReadBoardDesign.dynamic("#5FA66A", "#82BF8A")
    }

    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    public enum Radius {
        public static let sm: CGFloat = 4
        public static let md: CGFloat = 6
        public static let lg: CGFloat = 8
        public static let xl: CGFloat = 10
    }

    public enum Line {
        public static let hair: CGFloat = 0.5
    }

    public enum Shadow {
        public static let floatingColor = ReadBoardDesign.dynamic("#282622", "#000000")
        public static let floatingOpacity: Double = 0.10
        public static let floatingRadius: CGFloat = 14
        public static let floatingY: CGFloat = 5
    }

    public enum Track {
        public static let section: CGFloat = 0.8
    }

    public enum F {
        public static let rowTitle: CGFloat = 14
        public static let rowExcerpt: CGFloat = 12
        public static let rowMeta: CGFloat = 11
        public static let badge: CGFloat = 9
        public static let sidebar: CGFloat = 13
        public static let count: CGFloat = 11
        public static let section: CGFloat = 11
        public static let pageTitle: CGFloat = 17
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(readBoardHex: String) {
        let rgb = readBoardRGB(readBoardHex)
        self.init(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}
#else
private extension UIColor {
    convenience init(readBoardHex: String) {
        let rgb = readBoardRGB(readBoardHex)
        self.init(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
    }
}
#endif

private func readBoardRGB(_ value: String) -> (CGFloat, CGFloat, CGFloat) {
    let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    let number = UInt64(hex, radix: 16) ?? 0
    return (
        CGFloat((number >> 16) & 255) / 255,
        CGFloat((number >> 8) & 255) / 255,
        CGFloat(number & 255) / 255)
}
