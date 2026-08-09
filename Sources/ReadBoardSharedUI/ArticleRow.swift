#if os(macOS)
import SwiftUI
import ReadBoardContract

public struct ArticleRow: View {
    let item: ContentSummary
    let isSelected: Bool
    /// 乐观已读覆盖（open() 点未读后由 vm.readMarks 传入——不碰 items 数据源）
    var isReadOverride: Bool? = nil
    /// 有效已读态（覆盖优先，其次 item 字段）
    private var isRead: Bool { isReadOverride ?? item.isRead }
    let scale: Double
    let density: String
    let showSource: Bool
    let showDate: Bool
    let unreadBold: Bool
    let dateFormat: String

    /// 紧凑密度下行距更紧。
    private var isCompact: Bool { density == "compact" }

    /// 平台图标以订阅源 stype 为准，不再用内容 ctype。RSS/Podcast 保留原有
    /// 语义图标；YouTube/BiliBili/微信用平台典型符号和低饱和品牌色。
    private var platformIcon: String? {
        switch platformType {
        case "podcast": return "mic.fill"
        case "youtube": return "play.rectangle.fill"
        case "bilibili": return "tv.fill"
        case "wechat": return "message.badge.filled.fill"
        default: return nil  // RSS 用自定义 ReadBoardRSSIcon 组件，不走 SF Symbol
        }
    }

    private var platformIconColor: Color {
        switch platformType {
        case "podcast": return ReadBoardDesign.C.podcast
        case "youtube": return ReadBoardDesign.C.youtube
        case "bilibili": return ReadBoardDesign.C.bilibili
        case "wechat": return ReadBoardDesign.C.wechat
        default: return ReadBoardDesign.C.text3
        }
    }

    /// 历史 content.source 不完全等于订阅源 stype（早期 podcast 条目曾写成 rss）。
    /// 优先用 LEFT JOIN 拿到的 content_source.stype；无源/旧数据再回落到 source。
    private var platformType: String {
        (item.sourceType ?? item.source).lowercased()
    }

    private var isRSSPlatform: Bool {
        platformType == "rss" || platformType == "article"
    }

    /// 显示标题：媒体项优先标题译文（llm_title_translated）；否则有正文译文取 translatedHead 第一个非空行；都没有用原标题
    private var displayTitle: String {
        // 媒体项：标题译文（独立的 llm_title_translated 字段，不再靠 excerptTranslated 第一行猜）
        if let t = item.translatedTitle, !t.isEmpty {
            return t
        }
        guard let head = item.translatedHead, !head.isEmpty else {
            return item.title
        }
        // 跳过空行取第一个非空行（llm_translated_md 开头常是空行，第二行才是标题）
        let firstNonEmpty = head.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let cleaned = firstNonEmpty.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
        return cleaned.isEmpty ? item.title : cleaned
    }

    public init(
        item: ContentSummary,
        isSelected: Bool,
        isReadOverride: Bool? = nil,
        scale: Double,
        density: String,
        showSource: Bool,
        showDate: Bool,
        unreadBold: Bool,
        dateFormat: String
    ) {
        self.item = item
        self.isSelected = isSelected
        self.isReadOverride = isReadOverride
        self.scale = scale
        self.density = density
        self.showSource = showSource
        self.showDate = showDate
        self.unreadBold = unreadBold
        self.dateFormat = dateFormat
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 9) {
            // 未读点固定在整行最左侧并垂直居中；已读时保留槽位，正文不会左右跳。
            Circle()
                .fill(isRead ? Color.clear : ReadBoardDesign.C.accent)
                .frame(width: 6, height: 6)
                .frame(width: 8)

            VStack(alignment: .leading, spacing: isCompact ? 4 : 6) {
                // 第一行：标题 + 星标
                HStack(alignment: .top, spacing: 6) {
                    Text(displayTitle)
                        .font(.system(size: ReadBoardDesign.F.rowTitle * scale, weight: (unreadBold && !isRead) ? .semibold : .regular))
                        // 系统 List 高亮在窗口活跃/非活跃时都会压暗背景；选中标题固定用
                        // 浅灰，避免已读项继续沿用 rbText2 后与高亮底混在一起。
                        .foregroundStyle(isSelected ? Color.white.opacity(0.82) : (isRead ? ReadBoardDesign.C.text2 : ReadBoardDesign.C.text))
                        .lineLimit(isCompact ? 1 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(ReadBoardDesign.C.star)
                            .font(.system(size: 11 * scale))
                    }
                    Spacer(minLength: 0)
                }

                // 第二行：平台图标 + 订阅源名称 + 时间
                HStack(spacing: 6) {
                    if isRSSPlatform {
                        ReadBoardRSSIcon(size: 11, color: ReadBoardDesign.C.rss)
                    } else if let icon = platformIcon {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundStyle(platformIconColor)
                    }
                    if showSource {
                        Text(item.sourceName ?? item.source)
                            .font(.system(size: ReadBoardDesign.F.rowMeta * scale))
                            .foregroundStyle(ReadBoardDesign.C.text3)
                            .lineLimit(1)
                    }
                    if showSource, showDate, item.publishedAt != nil {
                        Text("·").foregroundStyle(ReadBoardDesign.C.text3)
                    }
                    if showDate, let publishedAt = item.publishedAt {
                        Text(formattedDate(publishedAt))
                            .font(.system(size: ReadBoardDesign.F.rowMeta * scale))
                            .foregroundStyle(ReadBoardDesign.C.text3)
                    }
                    Spacer(minLength: 0)
                }

                // 第三行：加工状态；已导出与前五项分开并固定靠右。
                HStack(spacing: 6) {
                    if let accessBadge {
                        ReadBoardBadge(text: accessBadge.text, color: accessBadge.color, scale: scale)
                    }
                    if item.contentType != "podcast", item.hasFulltext {
                        ReadBoardBadge(text: "全文", color: ReadBoardDesign.C.scoreHigh, scale: scale)
                    }
                    if let s = item.score {
                        Text("评分 \(s)")
                            .font(.system(size: ReadBoardDesign.F.badge * scale, weight: .medium))
                            .foregroundStyle(scoreColor(s))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(scoreColor(s).opacity(0.10))
                            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.sm))
                            .overlay(
                                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.sm)
                                    .strokeBorder(scoreColor(s).opacity(0.22), lineWidth: ReadBoardDesign.Line.hair)
                            )
                    }
                    if let sum = item.summary, !sum.isEmpty {
                        ReadBoardBadge(text: "摘要", color: ReadBoardDesign.C.summary, scale: scale)
                    }
                    if item.hasTranslation {
                        ReadBoardBadge(text: "翻译", color: ReadBoardDesign.C.translate, scale: scale)
                    }
                    if item.isMedia && item.hasTranscript {
                        ReadBoardBadge(text: "转录", color: ReadBoardDesign.C.summary, scale: scale)
                    }
                    Spacer(minLength: 8)
                    if item.hasExport {
                        ReadBoardBadge(text: "已导出", color: ReadBoardDesign.C.accent, scale: scale)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCompact ? 4 : 8)
        .contentShape(Rectangle())
        .readBoardSelection(isSelected, radius: ReadBoardDesign.Radius.lg)
    }

    /// 日期格式：relative=相对（x 分钟/小时/天前）/ absolute=绝对（yyyy-MM-dd）
    private func formattedDate(_ publishedAt: Int64) -> String {
        if dateFormat == "relative" {
            return Self.relativeDate(from: publishedAt)
        }
        return ReadingView.metadataDateString(epoch: publishedAt)
    }

    private var accessBadge: (text: String, color: Color)? {
        switch item.accessState {
        case "paidPreview": return ("单片付费", ReadBoardDesign.C.scoreLow)
        case "paidSeason": return ("付费合集", ReadBoardDesign.C.scoreLow)
        case "upowerExclusive": return ("充电专属", ReadBoardDesign.C.scoreMid)
        case "upowerEarlyAccess": return ("充电抢先看", ReadBoardDesign.C.scoreMid)
        case "loginRequired": return ("需登录", ReadBoardDesign.C.text2)
        default: return nil
        }
    }

    /// 相对时间（Unix epoch → x 分钟/小时/天前）
    static func relativeDate(from epoch: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86400 { return "\(seconds / 3600) 小时前" }
        if seconds < 86400 * 7 { return "\(seconds / 86400) 天前" }
        return ReadingView.metadataDateString(epoch: epoch)
    }

    /// 评分颜色分段（降饱和语义色）：90+ 灰绿 / 75-84 墨蓝 / 60-74 赭 / 1-59 砖红 / 0 灰
    private func scoreColor(_ s: Int) -> Color {
        switch s {
        case 90...: return ReadBoardDesign.C.scoreHigh
        case 75..<90: return ReadBoardDesign.C.scoreGood
        case 60..<75: return ReadBoardDesign.C.scoreMid
        case 1..<60: return ReadBoardDesign.C.scoreLow
        default: return ReadBoardDesign.C.scoreNone   // 0 分
        }
    }
}


public extension View {
    func readBoardSelection(
        _ selected: Bool,
        radius: CGFloat = ReadBoardDesign.Radius.md
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius)
                .fill(selected ? ReadBoardDesign.C.accent.opacity(0.10) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 2)
                    .fill(ReadBoardDesign.C.accent)
                    .frame(width: 2.5)
                    .padding(.vertical, 3)
            }
        }
    }
}
#endif
