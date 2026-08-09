#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import ReadBoardContract

public struct ReadingView: View {
    let item: ContentSummary
    @Binding var showTranslated: Bool
    private let library: any LibraryGateway
    private let contentDetail: any ContentDetailGateway
    private let mediaPlayback: any MediaPlaybackGateway
    private let processing: any ProcessingGateway
    private let export: any ExportGateway
    private let permissions: ReadBoardPermissionSet
    /// 上一篇/下一篇导航回调（阅读区顶部按钮，键盘 j/k 的图形化对应）
    var onPrev: (() -> Void)? = nil
    var onNext: (() -> Void)? = nil

    @State private var llmAvailable = false  // 在 onAppear 中赋值，避免 body 渲染时调 isAvailable→SecretStore 递归锁崩溃
    @ObservedObject private var processingStates = ContentProcessingStateStore.shared
    /// 媒体项（播客/视频）正文标签：0=原文(简介) / 1=译文(简介翻译) / 2=转录(中英对照)
    /// @AppStorage 持久化——记住上次读的标签，切文章不重置（和 viewMode 同模式）
    @AppStorage("reading.mediaTab") private var mediaTab = 0
    /// 版面设置（@AppStorage 直绑——设置面板/阅读器设置页改这里视图自动刷新，
    /// 不再像 @State 静态读 UserDefaults 只在创建读一次。和 uiFontScale 同模式）
    @AppStorage("reading.fontSize") private var fontSize: Double = 16
    @AppStorage("reading.lineSpacing") private var lineSpacing: Double = 6
    @AppStorage("reading.contentWidth") private var contentWidth: Double = 720
    @AppStorage("reading.theme") private var themeRaw: String = "claude"
    @AppStorage("reading.themeMode") private var themeModeRaw: String = "system"
    @AppStorage("reading.font") private var fontRaw: String = "system"
    @AppStorage("reading.titleFontSize") private var titleFontSize: Double = 24
    @AppStorage("reading.metaFontSize") private var metaFontSize: Double = 12
    @AppStorage("reading.summaryFontSize") private var summaryFontSize: Double = 14
    /// 界面缩放（@AppStorage 直绑——layoutPanel 里改这里视图自动刷新，
    /// 同时 ContentView/ArticleRow 的同名 @AppStorage 也会跟着重建，全局生效）
    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1.0
    @State private var showLayoutPopover = false
    @State private var showShareSheet = false
    /// 正文 frontmatter 块是否展开（默认收起，记住状态）
    @AppStorage("reading.metaExpanded") private var metaExpanded: Bool = false
    /// 星标/已读状态（本地镜像，操作后即时反馈，不依赖 reload）
    @State private var isStarred = false
    @State private var isRead = false

    public init(
        item: ContentSummary,
        showTranslated: Binding<Bool>,
        library: any LibraryGateway,
        contentDetail: any ContentDetailGateway,
        mediaPlayback: any MediaPlaybackGateway,
        processing: any ProcessingGateway,
        export: any ExportGateway,
        permissions: ReadBoardPermissionSet = .localFullControl,
        onPrev: (() -> Void)? = nil,
        onNext: (() -> Void)? = nil
    ) {
        self.item = item
        _showTranslated = showTranslated
        self.library = library
        self.contentDetail = contentDetail
        self.mediaPlayback = mediaPlayback
        self.processing = processing
        self.export = export
        self.permissions = permissions
        self.onPrev = onPrev
        self.onNext = onNext
    }

    /// theme/themeMode/fontChoice 从 raw 键派生（@AppStorage 存 String rawValue）
    private var theme: ReadingTheme {
        get { ReadingTheme(rawValue: themeRaw) ?? .claude }
        nonmutating set { themeRaw = newValue.rawValue }
    }
    private var themeMode: ReadingTheme.Mode {
        get { ReadingTheme.Mode(rawValue: themeModeRaw) ?? .light }
        nonmutating set { themeModeRaw = newValue.rawValue }
    }
    private var fontChoice: ReadingFont {
        get {
            if fontRaw.hasPrefix("custom:") { return .custom(String(fontRaw.dropFirst(7))) }
            switch fontRaw {
            case "heiti": return .heiti
            case "kaiti": return .kaiti
            case "fangsong": return .fangsong
            default: return .system
            }
        }
        nonmutating set {
            switch newValue {
            case .system: fontRaw = "system"
            case .heiti: fontRaw = "heiti"
            case .kaiti: fontRaw = "kaiti"
            case .fangsong: fontRaw = "fangsong"
            case .custom(let n): fontRaw = "custom:\(n)"
            }
        }
    }

    public var body: some View {
        fullBody
    }

    private var processingState: ContentProcessingStateStore.Entry? {
        processingStates.state(for: item.id)
    }

    private var busy: Bool { processingState?.isProcessing == true }
    private var statusMsg: String? { processingState?.message }

    private var fullBody: some View {
        VStack(spacing: 0) {
            // ── 顶部操作条：左右操作槽等宽，文稿标签占满中间区域并保持整体居中。──
            HStack(spacing: 12) {
                HStack(spacing: 2) {
                    // 快捷操作簇（统一 15pt + frame 24×24 对齐，SF Symbol 视觉大小归一）
                    if canUpdateReadingState {
                        Button { toggleStar() } label: {
                            Image(systemName: isStarred ? "star.fill" : "star")
                                .font(.system(size: 15, weight: .regular))
                                .frame(width: 24, height: 24)
                                .foregroundStyle(isStarred ? ReadBoardDesign.C.star : ReadBoardDesign.C.text2)
                        }
                        .buttonStyle(ReadBoardStaticQuietButtonStyle())
                        .help(isStarred ? "取消星标" : "加星标")

                        Button { toggleRead() } label: {
                            Image(systemName: isRead ? "envelope.open" : "envelope")
                                .font(.system(size: 15, weight: .regular))
                                .frame(width: 24, height: 24)
                                .foregroundStyle(ReadBoardDesign.C.text2)
                        }
                        .buttonStyle(ReadBoardStaticQuietButtonStyle())
                        .help(isRead ? "标为未读" : "标为已读")
                    }

                    Button { showShareSheet = true } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(ReadBoardDesign.C.text2)
                    }
                    .buttonStyle(ReadBoardStaticQuietButtonStyle())
                    .help("分享 / 后处理")
                }
                .frame(width: 76, alignment: .leading)

                // 视图切换：非媒体项「译文/原文」两段；媒体项「原文/译文/转录」三段（同一组件同一位置）
                if isMediaItem {
                    // 媒体标签分别由各自字段决定：译文看 llm_translated_md，
                    // 转录看 llm_transcript_md；二者互不作为对方的显示条件。
                    ReadBoardSegmented(
                        items: mediaTabItems,
                        selection: mediaTabSelection,
                        fillsAvailableWidth: false
                    )
                    .frame(maxWidth: .infinity)
                // ⚠️ 切标签"点了没反应"根治（09:21 用户直觉定位：在等通知但通知没给到，是个低级问题）：
                // 原判断 `!= nil` —— llm_translated_md=0KB 的文章 loadedTranslatedMd 是**空字符串 ""（非 nil）**，
                // `!= nil` 通过 → 标签显示"译文/原文"；但正文 hasTranslated 判断是 `!$0.isEmpty`，
                // 空串 → false → 正文只渲染原文 → 点"译文"画面不变（你以为没识别，其实是没内容可切）。
                // 修复：标签显示条件与正文一致——译文**非空**才显示切换标签。
                } else if translatedText != nil {
                    ReadBoardSegmented(
                        items: [(0, "译文"), (1, "原文")],
                        selection: $viewMode,
                        fillsAvailableWidth: false
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    Spacer(minLength: 0)
                }

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    // 明确显示 Aa 字标；不再沿用此前没有产生视觉变化的 textformat 图标。
                    Button { showLayoutPopover = true } label: {
                        Text("Aa")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .frame(width: 24, height: 24)
                            .foregroundStyle(ReadBoardDesign.C.text2)
                    }
                    .buttonStyle(ReadBoardStaticQuietButtonStyle())
                    .help("阅读器设置")
                    .popover(isPresented: $showLayoutPopover, arrowEdge: .bottom) {
                        layoutPanel
                    }
                }
                .frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(ReadBoardDesign.C.bg)   // 弃 .bar 材质（实时模糊有开销）改纯色更干净

            ReadBoardHairline()

            // ── 正文滚动区 ──
            // ⚠️ 切标签「不上屏」的稳定兜底：标签键挂 ScrollView，切标签 = 重建滚动区。
            // （上游「视图更新中发布」根因已修——见 ContentViewModel.init；但重建路径已被
            // 多轮实测确认可靠，先保留。后续验证就地更新稳定后可移除以保留滚动位置。）
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // 原生 NSTextView 同时处理拖选、单击和 pointing-hand cursor rect。
                    ReadBoardSelectableLinkTitle(
                        text: item.title,
                        destination: item.url,
                        font: fontChoice.nsFont(size: titleFontSize, bold: true),
                        normalColor: NSColor(p.text),
                        hoverColor: NSColor(ReadBoardDesign.C.accent.opacity(0.88))
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help("点击在浏览器打开原文")
                    // 中文标题（有译文时显示在英文标题下方——从 translatedHead 第一行取）
                    if let chineseTitle = chineseTitle, chineseTitle != item.title {
                        Text(chineseTitle)
                            .font(fontChoice.font(size: titleFontSize * 0.75).weight(.medium))
                            .foregroundStyle(p.textSecondary)
                            .textSelection(.enabled)
                    }
                    // 元信息（类型图标 + 源名称 · 作者 · 日期 · 评分）
                    if !metaParts.isEmpty {
                        HStack(spacing: 6) {
                            let ctype = item.contentType
                            if ctype == "podcast" {
                                Image(systemName: "mic.fill")
                                    .foregroundStyle(ReadBoardDesign.C.podcast)
                            } else if ctype == "video" || ctype == "youtube" {
                                Image(systemName: "play.rectangle.fill")
                                    .foregroundStyle(ReadBoardDesign.C.video)
                            } else if ctype != "wechat" && ctype != "social" {
                                ReadBoardRSSIcon(size: metaFontSize, color: ReadBoardDesign.C.rss)
                            }
                            Text(metaParts.joined(separator: "  ·  "))
                        }
                        .font(.system(size: metaFontSize))
                        .foregroundStyle(p.textSecondary)
                    }

                    // ── 媒体播放器（固定顶部——切标签不动）──
                    // 播客：音频播放器（loadedAudioUrl 判据，见下注释）。
                    // YouTube/视频：视频播放器（loadedVideoId 判据，从 meta.video_id 回填）。
                    // ⚠️ 判据用 loadedAudioUrl/loadedVideoId 而非 item.audioUrl/videoId：
                    // 轻列查询不取媒体地址（Database.swift:993 写死"媒体地址点开再查"），
                    // item 上这两个字段恒 nil；loaded* 在 onAppear 的 loadContentMd() 里从
                    // fetchContentBody 同步回填（与 loadedContentMd 同构，安全不替换 item）。
                    if item.contentType == "podcast", let audioUrl = loadedAudioUrl, !audioUrl.isEmpty {
                        ReadBoardAudioPlayerView(audioUrl: audioUrl, title: item.title)
                            .padding(.vertical, 4)
                    } else if (item.contentType == "video" || item.contentType == "youtube"),
                              let vid = loadedVideoId, !vid.isEmpty {
                        switch ReadBoardVideoPlayerPlatform.resolve(
                            source: item.sourceType ?? item.source) {
                        case .bilibili:
                            ReadBoardBilibiliPlayerView(
                                bvid: vid,
                                title: item.title,
                                pageURL: item.url)
                                .padding(.vertical, 4)
                        case .youtube:
                            ReadBoardYouTubePlayerView(
                                videoID: vid,
                                title: item.title,
                                mediaPlayback: mediaPlayback)
                                .padding(.vertical, 4)
                        }
                    }

                    // ── LLM 操作条（胶囊按钮组 + 状态提示，精致排版）──
                    // 这套是阅读器唯一的操作按钮组（右上角已只留格式）。
                    // 所有按钮都是单篇手动操作/重操作，不受文件夹/订阅源自动开关限制。
                    if canRunProcessing {
                        HStack(spacing: 8) {
                        // 提取全文：不需 LLM，任何项都可点（抓正文/重抓）
                        ReadBoardStaticCapsuleButton(title: "提取全文", icon: "doc.text", disabled: busy) { runFulltext() }
                        // 内容处理：按源开关重新跑已开启管线（一次点击跑全部）
                        ReadBoardStaticCapsuleButton(title: "内容处理", icon: "gearshape.2", disabled: busy) {
                            reprocessFromReadingView()
                        }
                        if llmAvailable {
                            // 评分/摘要/翻译按钮：均始终显示，已有结果也可重新执行
                            ReadBoardStaticCapsuleButton(title: "AI 评分", icon: "star", disabled: busy) { runScore() }
                            ReadBoardStaticCapsuleButton(title: "AI 摘要", icon: "text.quote", disabled: busy) { runSummarize() }
                            ReadBoardStaticCapsuleButton(title: "AI 翻译", icon: "character.bubble", disabled: busy) { runTranslate() }
                        }
                        // AI 转录：媒体项始终显示（放最后）；已有转录稿也显示（可重新转录）
                        if isMediaItem {
                            ReadBoardStaticCapsuleButton(title: "AI 转录", icon: "waveform", disabled: busy) { runTranscribe() }
                        }
                        // 所有状态统一位于最后一个操作按钮右侧。
                        if busy {
                            ProgressView().scaleEffect(0.6).frame(width: 16, height: 16)
                        }
                        if let msg = statusMsg {
                            Text(msg)
                                .font(.caption)
                                .foregroundStyle(msg.contains("失败") ? ReadBoardDesign.C.scoreLow : ReadBoardDesign.C.text3)
                                .lineLimit(1)
                                .help(msg)
                        } else if !llmAvailable, !isMediaItem {
                            Label("未配置 LLM Key", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(ReadBoardDesign.C.scoreLow)
                        }
                        Spacer()
                        }
                        .padding(.vertical, 2)
                    }

                    ReadBoardHairline()

                    // 摘要（灰紫缘引用卡：独立字号设置；effectiveSummary 镜像优先——AI 完成后即刻上屏）
                    if let sum = effectiveSummary, !sum.isEmpty {
                        Text(sum)
                            .font(.system(size: summaryFontSize))
                            .foregroundStyle(p.textSecondary)
                            .lineSpacing(3)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(p.backgroundAlt)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(ReadBoardDesign.C.summary.opacity(0.85))
                                    .frame(width: 3)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
                    }

                    // 正文：媒体项按三标签渲染，非媒体项统一用 MarkdownBodyView。
                    // ⚠️ 关键修复：原代码用三分支（if isMediaItem / else if viewMode==0 let translated / else），
                    // 当 loadBodyIfNeeded 异步填回 item.llmTranslatedMd（nil→有值）时，
                    // 条件分支从"原文"切换到"译文" → VStack 子视图结构在布局期间变化 →
                    // StackLayout.makeChildren → use-after-free 崩溃。
                    // 修复：非媒体项统一渲染 MarkdownBodyView(displayMd)，用计算属性选择译文/原文内容。
                    // item 字段异步变化只改 markdown 参数值，不改子视图类型/数量，布局安全。
                    if isMediaItem {
                        mediaBodyView
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        // 正文渲染：f269c64 稳定设计（后台解析 + @State 写回，详见 ReadingTheme.swift 注释）。
                        // 切标签秒切由两层保证：① 通知回调改 GCD（视图更新中发布根因已除）；
                        // ② ScrollView 随标签重建（实测确认的稳定路径，代价是滚动位置回顶）。
                        MarkdownBodyView(
                            markdown: displayMd,
                            theme: theme, mode: themeMode, fontChoice: fontChoice,
                            fontSize: fontSize, lineSpacing: lineSpacing
                        )
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 28)
                .frame(maxWidth: contentWidth)
                .frame(maxWidth: .infinity)   // 内容限宽后居中
            }
            // 切标签连同 ScrollView 一起重建（实测确认的稳定路径，代价是滚动位置回顶）
            .id("reading-body-\(viewMode)-\(effectiveMediaTab)")
            .background(p.background)   // 主题底色
        }
        // 视图随 .id(item.id) 重建，onAppear 即切文章——刷新有效开关与本地状态
        .onAppear {
            Task {
                llmAvailable = await processing.capabilities().llmAvailable
            }
            isStarred = item.isStarred
            isRead = item.isRead
        }
        // 正文、译文、转录、评分、摘要和源策略一次后台读取；不再在 onAppear 主线程查两遍 DB。
        .task(id: item.id) { await loadContentMd() }
        .onChange(of: processingState?.isProcessing) { wasProcessing, isProcessing in
            if wasProcessing == true, isProcessing == false {
                refreshLoadedBody()
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(item: item, export: export, permissions: permissions)
        }
    }

    /// 元信息片段（作者/日期/评分）——编辑部点分隔风格，有则收集
    private var metaParts: [String] {
        var parts: [String] = []
        if let sn = item.sourceName, !sn.isEmpty { parts.append(sn) }
        if let a = item.author, !a.isEmpty { parts.append(a) }
        if let publishedAt = item.publishedAt {
            parts.append(Self.metadataDateString(epoch: publishedAt))
        }
        if let s = effectiveScore { parts.append("评分 \(s)") }
        return parts
    }

    private static let metadataDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Core 旧视图直接取数据库时间字符串的日期部分；使用 UTC 才能保持同一口径，
        // 避免东八区把深夜发布的文章显示到第二天。
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func metadataDateString(epoch: Int64) -> String {
        metadataDate.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// 右上角直接复用设置页完整的阅读器设置，避免两处配置项和取值范围再次分叉。
    private var layoutPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("阅读器设置")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ReadBoardDesign.C.text)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ReadBoardReaderPane()
        }
        .frame(width: 480, height: 620)
    }

    // MARK: 快捷操作（本地即时反馈 + 通知列表刷新）

    private func toggleStar() {
        let target = !isStarred
        isStarred = target
        let contentID = item.id
        Task {
            do {
                let state = try await library.setStarred(
                    contentID: contentID,
                    isStarred: target)
                NotificationCenter.default.post(
                    name: .readBoardContentUpdated,
                    object: state)
            } catch {
                // 快速连续点击时，只撤销仍与本次请求目标一致的乐观状态。
                if isStarred == target { isStarred = !target }
            }
        }
    }

    private func toggleRead() {
        let targetRead = !isRead
        isRead = targetRead
        let contentID = item.id
        Task {
            do {
                let state = try await library.setRead(
                    contentID: contentID,
                    isRead: targetRead)
                // 写入确认后再通知列表刷新，避免 observer 读到旧状态。
                NotificationCenter.default.post(
                    name: .readBoardContentUpdated,
                    object: state)
            } catch {
                if isRead == targetRead { isRead = !targetRead }
            }
        }
    }

    private var canUpdateReadingState: Bool {
        permissions.allows(.updateReadingState, capability: .library)
    }

    private var canRunProcessing: Bool {
        permissions.allows(.runProcessing, capability: .processing)
    }

    /// 正文视图模式：0=双语对照 / 1=仅原文 / 2=仅译文。
    /// @AppStorage 持久化——你的选择记住，切文章/重启不重置。默认双语对照（Follo 风格）。
    /// ⚠️ 09:23 实测：@State 和 @AppStorage 都复现"点两次才切"，证明延迟不在存储层。
    /// 真正机制：自定义 Binding 的 set 在 onTapGesture 回调里改 @State，若同一 runloop body 已求值过，
    /// 这次变更被合并到下一次 body 求值 → 第一次点击没立即重绘，第二次点击又触发 body 才带出。
    /// 改回 @AppStorage 直绑（系统保证读写同步、立即触发 body），去掉自定义 Binding 中间层。
    @AppStorage("reading.viewMode") private var viewMode: Int = 0
    /// 双语对照模式（viewMode=0 且有译文）
    private var bilingualMode: Bool {
        viewMode == 0 && translatedText != nil
    }

    private var bodyText: String {
        // 双语/仅原文：优先原文 md（contentMd ?? excerpt）
        if let md = loadedContentMd, !md.isEmpty { return md }
        return item.excerpt ?? "(无内容)"
    }

    /// 正文渲染用 markdown：viewMode 0 优先译文，viewMode 1 或无译文用原文。
    /// ⚠️ 09:36 用户定位「点原文秒切、点译文要等；播客切换不卡」→ 根因是译文走 @State 依赖链。
    /// 播客译文直接读 item.llmTranslatedMd（let 属性，同步确定）→ 秒切；
    /// RSS 译文走 loadedTranslatedMd(@State) → 与刚变的 viewMode 同帧快照错位 → 第一次求值不一致。
    /// 对齐播客：译文**优先读 item.llmTranslatedMd**（读 let 属性安全，崩溃是"异步替换 selectedItem"
    /// 导致的，读属性不触发），@State loadedTranslatedMd 仅作 item 无译文时的兜底。
    /// 译文文本——同步、确定，与播客读 item 字段等价。
    /// 不走 @State（@State 写入有"延迟一帧提交"语义，与 viewMode 变更同帧快照错位 → 点译文要等）。
    /// 改为 body 求值时同步查 DB（fetchContentBody 实测 0ms），随取随用，与 viewMode 变更同帧一致。
    /// 列表是轻列 item.llmTranslatedMd=nil，译文只能查 DB；用 memo 字典按 id 缓存避免重复查。
    private var translatedText: String? {
        // ⚠️ 只读 @State 镜像，绝不在 body 求值里查 DB（16:03 定案）：
        // 09:36 加的「body 求值时同步 fetchContentBody 兜底」让每次求值都跑 1~3 次 SQL
        // （标签条件/displayMd/chineseTitle），每开一篇文章 ~10 次求值 = 几十次主线程查询
        // + 几十条 dblock 日志——渲染成本爆炸，快速连点时 AG 更新相互踩踏 → cycle → 闪退。
        // 「@State 延迟一帧」当年看似要等，根因是通知回调"视图更新中发布"丢帧（已根治），
        // 现在镜像写入后一帧即上屏，不需要 DB 兜底。
        if let t = loadedTranslatedMd, !t.isEmpty { return t }
        return nil
    }

    private var displayMd: String {
        if viewMode == 0, let t = translatedText { return t }
        return bodyText
    }

    /// 是否媒体项（播客/视频，可转录）
    private var isMediaItem: Bool {
        item.contentType == "podcast" || item.contentType == "video" || item.contentType == "youtube" || item.isMedia
    }

    // MARK: 媒体项三标签（原文/译文/转录）

    /// 媒体标签动态组合：原文始终存在，译文和转录分别检查自己的字段。
    private var mediaTabItems: [(Int, String)] {
        Self.mediaTabOptions(hasTranslation: translatedText != nil, hasTranscript: hasTranscript)
    }

    /// 纯逻辑入口，供回归测试验证四种译文/转录组合。
    nonisolated static func mediaTabOptions(hasTranslation: Bool, hasTranscript: Bool) -> [(Int, String)] {
        var tabs: [(Int, String)] = [(0, "原文")]
        if hasTranslation { tabs.append((1, "译文")) }
        if hasTranscript { tabs.append((2, "转录")) }
        return tabs
    }

    private var hasTranscript: Bool {
        guard let text = loadedTranscriptMd else { return false }
        return !text.isEmpty
    }

    /// mediaTab 用 @AppStorage 记住上次选择；切到不具备该内容的媒体时安全回退原文。
    private var effectiveMediaTab: Int {
        mediaTabItems.contains(where: { $0.0 == mediaTab }) ? mediaTab : 0
    }

    private var mediaTabSelection: Binding<Int> {
        Binding(
            get: { effectiveMediaTab },
            set: { mediaTab = $0 }
        )
    }

    /// feed 简介原文（excerpt 已是剥标签纯文本——播客简介存摘要字段；兜底 content_html 剥标签兼容旧数据）
    private var excerptPlainText: String {
        if let ex = item.excerpt, !ex.isEmpty { return ex }
        return "(无简介)"
    }

    /// 媒体项正文（按 mediaTab 渲染对应内容；无转录稿时 mediaTab=2 钳制回原文）
    /// ⚠️ 与 RSS 正文同一根治：原实现 @ViewBuilder switch 三分支（Text / MarkdownBodyView 混用），
    /// 切标签 = 换分支 = 子树换类型重建 → 与 .id 相同的「首次渲染被推迟」隐患。
    /// 改为计算属性出 markdown + 单一 MarkdownBodyView（身份稳定，就地更新，同事务上屏）。
    private var mediaBodyMarkdown: String {
        switch effectiveMediaTab {
        case 0:
            // 原文：defuddle 抓到的全文（content_md），兜底 feed 简介
            if let md = loadedContentMd, !md.isEmpty { return md }
            return excerptPlainText
        case 1:
            // 译文：全文/简介翻译（llm_translated_md），与转录稿字段彼此独立。
            // 原用 effectiveExcerptTranslated（简介翻译 llm_excerpt_translated），
            // 但翻译全文（translate）只写 llm_translated_md 不写 llm_excerpt_translated，
            // 导致简介翻译永远空 → 「译文」标签永远「尚无译文」。
            if let t = translatedText { return t }
            return "尚无译文——点「翻译」生成中英对照译稿"
        default:
            // 转录：Whisper 转录稿（llm_transcript_md），独立于翻译稿
            if let t = loadedTranscriptMd, !t.isEmpty { return t }
            return "尚无转录稿——点「转录」生成中英文对照稿"
        }
    }

    @ViewBuilder
    private var mediaBodyView: some View {
        MarkdownBodyView(markdown: mediaBodyMarkdown, theme: theme, mode: themeMode, fontChoice: fontChoice,
                         fontSize: fontSize, lineSpacing: lineSpacing)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 中文标题：统一优先读 llm_title_translated（所有类型），
    /// null 时回退到译文正文首行提取（兼容旧翻译）。

    /// 中文标题（统一读 llm_title_translated，null 时回退译文首行提取）
    private var chineseTitle: String? {
        // 优先 llm_title_translated（所有类型统一——translate()/translateExcerpt() 都写这列）
        if let t = effectiveTitleTranslated, !t.isEmpty { return t }
        // 兜底：旧翻译 llm_title_translated 为空 → 从译文正文首行提取
        guard let translated = translatedText else { return nil }
        let firstNonEmpty = translated.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        var cleaned = firstNonEmpty.replacingOccurrences(of: "^标题：\\s*", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 当前 palette（按 themeMode 取——亮/暗切换即时生效）
    private var p: ThemePalette { theme.palette(for: themeMode) }

    // MARK: - LLM 操作

    /// AI 评分/翻译用的正文：优先 Markdown，退回 excerpt
    /// 正文内容——@State 缓存，打开时按 id 查 content_md（列表查询不取 content_md，
    /// selectedItem.contentMd 为 nil 导致 contentBody 用 excerpt 闪烁）
    @State private var loadedContentMd: String? = nil
    /// 译文（@State 缓存）——从 loadContentMd 同步加载（onAppear 时查 DB，<1ms）。
    /// 原来由 ContentViewModel.loadBodyIfNeeded 异步填回 selectedItem，但替换 selectedItem 实例
    /// 会导致 ReadingView 条件分支在布局期间切换 → use-after-free 崩溃。
    /// 改为 @State 后：onAppear 同步查 DB 填回 → displayMd 值变（但子视图结构不变）→ 安全。
    @State private var loadedTranslatedMd: String? = nil
    /// 标题译文镜像（中文标题用）——item 是轻列实例，列表查询不取，镜像从 fetchContentBody 补齐。
    @State private var loadedTitleTranslated: String? = nil
    /// 评分/摘要镜像（AI 完成后自动上屏用）——selectedItem 实例刻意不替换（会诱发
    /// AttributeGraph 无限重绘循环，12:10 hang 实锤），item 里的这两字段永远是打开时的旧值。
    @State private var loadedScore: Int? = nil
    @State private var loadedSummary: String? = nil
    /// 音频地址镜像（媒体项播放器用）——轻列查询不取 audio_url（Database.swift:993 写死
    /// "媒体地址点开再查"），item.audioUrl 恒为 nil。此处从 fetchContentBody 同步回填，
    /// 让 AudioPlayerView 的渲染判据成立。与 loadedContentMd 同构：onAppear 同步查、不替换 item。
    @State private var loadedAudioUrl: String? = nil
    /// 视频 id 镜像（YouTube 播放器用）——meta.video_id 同属"大字段点开再查"，
    /// 轻列 item 不含。从 fetchContentBody 第 7 元组回填，让 YouTubePlayerView 渲染判据成立。
    @State private var loadedVideoId: String? = nil
    /// 转录稿镜像（llm_transcript_md）。独立于翻译稿，供「转录」标签使用。
    @State private var loadedTranscriptMd: String? = nil
    @State private var readerPayloadLoaded = false

    /// 镜像优先的有效值（镜像未就绪时回退 item 字段）
    private var effectiveTitleTranslated: String? { loadedTitleTranslated ?? item.translatedTitle }
    private var effectiveScore: Int? { loadedScore ?? item.score }
    private var effectiveSummary: String? { loadedSummary ?? item.summary }

    /// 打开时从阅读器专用连接一次加载所有所需字段，不受列表/Worker 长查询占用。
    @MainActor
    private func loadContentMd() async {
        guard !readerPayloadLoaded else { return }
        let contentId = item.id
        do {
            let detail = try await contentDetail.detail(contentID: contentId)
            guard !Task.isCancelled else { return }
            readerPayloadLoaded = true
            apply(detail)
        } catch {
            guard !Task.isCancelled else { return }
            readerPayloadLoaded = true
        }
    }

    /// LLM 任务完成后重查全部镜像（item 实例刻意不替换，新鲜度全走镜像/DB 兜底——
    /// 翻译/摘要/评分/转录完成后 译文标题、摘要卡、评分标、标签入口 即刻自动上屏）
    private func refreshLoadedBody() {
        let contentId = item.id
        Task { @MainActor in
            guard let detail = try? await contentDetail.detail(contentID: contentId),
                  contentId == item.id else { return }
            apply(detail)
        }
    }

    private func apply(_ detail: ContentDetail) {
        loadedContentMd = detail.contentMarkdown
        loadedTranslatedMd = detail.translatedMarkdown
        loadedTitleTranslated = detail.translatedTitle
        loadedAudioUrl = detail.audioURL
        loadedVideoId = detail.videoID
        loadedTranscriptMd = detail.transcriptMarkdown
        loadedScore = detail.score
        loadedSummary = detail.summary
    }

    /// 重新处理：按文章所属源的当前开关，重新跑所有已开启管线（阅读栏用，带状态反馈）
    private func reprocessFromReadingView() {
        runProcessing(.allEnabled)
    }

    private func runFulltext() {
        runProcessing(.fulltext)
    }

    private func runScore() {
        runProcessing(.score)
    }

    private func runTranslate() {
        runProcessing(.translate)
    }

    private func runSummarize() {
        runProcessing(.summarize)
    }

    private func runTranscribe() {
        runProcessing(.transcribe)
    }

    private func runProcessing(_ operation: ProcessingOperation) {
        ProcessingCommandCoordinator.start(
            gateway: processing,
            contentID: item.id,
            title: item.title,
            operation: operation
        ) { snapshot in
            guard snapshot.contentChanged else { return }
            refreshLoadedBody()
            if operation == .translate {
                if isMediaItem { mediaTab = 1 }
                else if viewMode == 1 { viewMode = 0 }
            } else if operation == .transcribe, viewMode == 1 {
                viewMode = 0
            }
        }
    }
}

// MARK: - 分享 / 后处理（阅读区）

public struct ShareSheet: View {
    let item: ContentSummary
    private let export: any ExportGateway
    private let permissions: ReadBoardPermissionSet
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""

    public init(
        item: ContentSummary,
        export: any ExportGateway,
        permissions: ReadBoardPermissionSet = .localFullControl
    ) {
        self.item = item
        self.export = export
        self.permissions = permissions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 头部：标题 + 文章名（两行克制排版）
            VStack(alignment: .leading, spacing: 6) {
                Text("分享 / 后处理")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ReadBoardDesign.C.text)
                Text(item.title)
                    .font(.system(size: 12))
                    .foregroundStyle(ReadBoardDesign.C.text3)
                    .lineLimit(2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ReadBoardHairline()

            // 动作行（hover 浮现 surface 底，hairline 分组）
            VStack(alignment: .leading, spacing: 2) {
                shareActionRow("复制链接", icon: "link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.url, forType: .string)
                    message = "✅ 链接已复制"
                }
                shareActionRow("复制标题 + 链接", icon: "doc.on.doc") {
                    let text = "\(item.title)\n\(item.url)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    message = "✅ 标题+链接已复制"
                }
                shareActionRow("在浏览器打开原文", icon: "safari") {
                    if let url = URL(string: item.url), !item.url.isEmpty {
                        NSWorkspace.shared.open(url)
                    }
                    dismiss()
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)

            if canManageExports {
                ReadBoardHairline()

                VStack(alignment: .leading, spacing: 2) {
                    shareActionRow("触发导出规则", icon: "square.and.arrow.up.on.square") {
                        Task {
                            _ = try? await export.forceExport(contentID: item.id)
                            message = "✅ 已触发手动导出规则"
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }

            if !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(ReadBoardDesign.C.scoreHigh)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }

            Spacer()

            ReadBoardHairline()
            HStack {
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(ReadBoardPrimaryCapsuleButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 400, height: 430)
    }

    private var canManageExports: Bool {
        permissions.allows(.manageExports, capability: .export)
    }

    /// 分享动作行：图标 + 文字整行可点，hover 浮现 surface 底
    private func shareActionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(ReadBoardDesign.C.text2)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(ReadBoardDesign.C.text)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(ReadBoardRowHoverButtonStyle())
    }
}
#endif
