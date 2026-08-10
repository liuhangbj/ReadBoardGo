import ReadBoardUI
import SwiftUI

/// 迁移期兼容层：Go 的现有调用名全部转发到 Core/Go 共用的 ReadBoardUI。
/// 新代码直接使用 ReadBoardDesign / ReadBoard* 组件，不再新增 Go 专属视觉组件。
typealias GoDesign = ReadBoardDesign
typealias GoHairline = ReadBoardHairline
typealias GoSectionLabel = ReadBoardSectionLabel
typealias GoBadge = ReadBoardBadge
typealias GoPanel<Content: View> = ReadBoardPanel<Content>
typealias GoMetricTile = ReadBoardMetricTile
typealias GoPageHeader<Trailing: View> = ReadBoardPageHeader<Trailing>
typealias GoPrimaryButtonStyle = ReadBoardPrimaryButtonStyle
typealias GoQuietButtonStyle = ReadBoardQuietButtonStyle
typealias GoSecondaryButtonStyle = ReadBoardSecondaryButtonStyle

extension Color {
    static let goBackground = ReadBoardDesign.C.bg
    static let goSidebar = ReadBoardDesign.C.bgSidebar
    static let goSurface = ReadBoardDesign.C.surface
    static let goText = ReadBoardDesign.C.text
    static let goTextSecondary = ReadBoardDesign.C.text2
    static let goTextTertiary = ReadBoardDesign.C.text3
    static let goAccent = ReadBoardDesign.C.accent
    static let goOnAccent = ReadBoardDesign.C.onAccent
    static let goHairline = ReadBoardDesign.C.hairline
    static let goSeparator = ReadBoardDesign.C.separator
    static let goSuccess = ReadBoardDesign.C.scoreHigh
    static let goWarning = ReadBoardDesign.C.scoreMid
    static let goError = ReadBoardDesign.C.scoreLow
    static let goStar = ReadBoardDesign.C.star
    static let goSummary = ReadBoardDesign.C.summary
    static let goTranslate = ReadBoardDesign.C.translate
    static let goRSS = ReadBoardDesign.C.rss
    static let goPodcast = ReadBoardDesign.C.podcast
    static let goVideo = ReadBoardDesign.C.video
    static let goBilibili = ReadBoardDesign.C.bilibili
    static let goWeChat = ReadBoardDesign.C.wechat
}

extension View {
    func goField(focused: Bool = false) -> some View {
        readBoardField(focused: focused)
    }

    func goSelected(_ selected: Bool) -> some View {
        readBoardSelected(selected)
    }
}
