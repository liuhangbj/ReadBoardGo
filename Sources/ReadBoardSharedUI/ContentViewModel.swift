import Foundation
import ReadBoardContract
import SwiftUI

@MainActor
public final class ContentViewModel: ObservableObject {
    @Published public var sidebarTree: [LibraryNode] = []   // 左栏树：文件夹→源
    @Published public var items: [ContentSummary] = []
    /// 左栏选中的过滤键：nil=全部，"source_id=N"=单源，"folder_id=N"=文件夹
    @Published public var selectedFilter: String? = nil
    @Published public var selectedItem: ContentSummary? = nil
    @Published public var minScore: Int = 0               // 评分区间下限，0=不限
    @Published public var maxScore: Int = 100             // 评分区间上限，100=不限
    @Published public var includeUnscored: Bool = false   // 评分筛选时是否含未评分
    /// 阅读状态单选：all=全部 / unread=未读 / starred=星标
    @Published public var readFilter: ReadFilter = .all
    /// 处理状态三态筛选：fulltext/score/summary/translate/transcribe。
    /// 每键三态：.none 不筛选 / .yes 已处理（实色高亮）/ .no 未处理（淡粉高亮）。
    /// 多选为「或」关系（满足任一条件即纳入），跨键可混合 yes/no。
    @Published public var processedStates: [String: ProcessedState] = [:]

    /// 处理状态三态：none=不筛选 / yes=已处理（实色）/ no=未处理（淡粉）
    public enum ProcessedState: Int {
        case none = 0, yes = 1, no = 2
        /// 点击循环：none → yes → no → none
        public var next: ProcessedState {
            switch self { case .none: return .yes; case .yes: return .no; case .no: return .none }
        }
    }
    @Published public var keyword: String = ""            // 搜索关键词（标题/正文）
    /// 文章列表排序：newest（最新优先，默认）/ oldest（最早优先）/ score（评分优先）
    @Published public var sortOrder: SortOrder = .newest

    public enum SortOrder: String, CaseIterable, Identifiable {
        case newest, oldest, score
        public var id: String { rawValue }
        public var display: String {
            switch self {
            case .newest: return "最新"
            case .oldest: return "最早"
            case .score: return "评分"
            }
        }
    }

    public enum ReadFilter: String, CaseIterable {
        case all, unread, starred
        public var display: String {
            switch self {
            case .all: return "全部"
            case .unread: return "未读"
            case .starred: return "星标"
            }
        }
    }
    @Published public var totalCount: Int = 0
    @Published public var totalUnread: Int = 0   // 全部文章未读数（左栏「全部文章」行显示 未读/总数）
    @Published public var totalPending: Int = 0  // 尚未达到条目设定处理标准的内容数
    @Published public var totalPendingUnread: Int = 0
    @Published public var totalExported: Int = 0  // 已导出文章数
    @Published public var totalExportedUnread: Int = 0
    @Published public var articleCount: Int = 0
    @Published public var articleUnread: Int = 0
    @Published public var podcastCount: Int = 0
    @Published public var podcastUnread: Int = 0
    @Published public var videoCount: Int = 0
    @Published public var videoUnread: Int = 0
    @Published public var showTranslated: Bool = false    // 阅读区显示原文/翻译
    @Published public var searchFocused: Bool = false     // 搜索框焦点（快捷键避让）

    /// 从 selectedFilter 解析 sourceId / folderId
    private var selectedSourceId: Int64? {
        guard let f = selectedFilter, f.hasPrefix("source_id=") else { return nil }
        return Int64(f.replacingOccurrences(of: "source_id=", with: ""))
    }
    private var selectedFolderId: Int64? {
        guard let f = selectedFilter, f.hasPrefix("folder_id=") else { return nil }
        return Int64(f.replacingOccurrences(of: "folder_id=", with: ""))
    }
    private var selectedContentCategory: String? {
        guard let f = selectedFilter, f.hasPrefix("ctype=") else { return nil }
        return String(f.dropFirst("ctype=".count))
    }
    private var pendingOnly: Bool { selectedFilter == "pending" }

    private let library: any LibraryGateway
    public let permissions: ReadBoardPermissionSet
    /// 搜索防抖：连续输入时取消上一次未执行的 reload
    private var searchTask: Task<Void, Never>?
    /// 搜索框输入时调用——300ms 防抖，避免每敲一字就全库查一次
    public func reloadDebounced() {
        searchTask?.cancel()
        searchTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    /// NotificationCenter observer token——block-based addObserver 的返回值须持有并在 deinit 移除，
    /// 否则 ViewModel 释放后 observer 注册泄漏（weak self 防崩溃但注册表越积越多）。
    /// nonisolated(unsafe)：NSObjectProtocol 非 Sendable，@MainActor 类的 deinit 是非隔离的，
    /// 直接访问存储属性会被 Swift 6 并发检查拦。observer token 本身线程安全（removeObserver 可任意线程调）。
    private nonisolated(unsafe) var updateObserver: NSObjectProtocol?

    public init(
        library: any LibraryGateway,
        permissions: ReadBoardPermissionSet = .localFullControl
    ) {
        self.library = library
        self.permissions = permissions
        // 评分/翻译完成后刷新列表。
        // ⚠️ 根因修复（11:47 系统日志符号化堆栈实锤）：
        // 原实现 `Task { @MainActor in self.reload() }` —— Task @MainActor 会被 SwiftUI
        // 在当前视图更新周期内排干执行 → reload() 写 @Published items 正中
        // "Publishing changes from within view updates is not allowed"
        // （堆栈：items.setter ← reload() ← 本闭包）→ 渲染提交被判 undefined behavior 丢弃，
        // 全 app 出现「点了不上屏、再点任意处才上屏」的家族病（切标签/AI按钮/摘要卡/译文标题/图片）。
        // GCD DispatchQueue.main.async 是独立 runloop 回调，不会被卷进视图更新周期——
        // 这是逃离"更新中发布"的标准通道。
        //
        // 同块内恢复刷新 selectedItem 实例（当年禁用是因 Task 在布局期执行→分支切换→UAF）：
        // GCD 延迟块在布局外执行，且 ContentSummary 相等只比 id（List 选中态保持）——
        // 两个崩溃前提都不在了。恢复后：翻译/摘要/评分完成 → 译文标题/摘要卡/评分标自动上屏，
        // 不再靠「切别的文章再切回来」。注意列表是轻列：llmTranslatedMd/contentMd 仍靠
        // ReadingView 的 @State/DB 兜底（translatedText），不依赖本实例。
        updateObserver = NotificationCenter.default.addObserver(
            forName: .readBoardContentUpdated, object: nil, queue: .main
        ) { [weak self] notification in
            // GCD 异步（非 Task @MainActor）——独立 runloop 回调，不会被 SwiftUI 卷进
            // 当前视图更新周期 → 不再触发 "Publishing changes from within view updates"。
            // ⚠️ 防抖合并（05:08 渲染风暴实锤）：后台管线每完成一件就 post 一次，
            // 逐次 reload = 300 行 + 300 个 AsyncImage 全量重建 ×N 次/分钟 → 内存疯涨 + AG cycle。
            // 0.75s 合并：连发只跑最后一次 reload，风暴砍成一次。
            let contentState = notification.object as? ContentState
            // 再跨一个独立 runloop：阅读工具条回填不会落进当前按钮/视图更新事务。
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    if let contentState { self?.apply(contentState) }
                    self?.scheduleContentReload()
                }
            }
        }
    }

    /// 通知防抖用的可取消工作项（连发 contentUpdated 时只保留最后一个）
    private var pendingReload: DispatchWorkItem?

    private func scheduleContentReload() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.reload()
                self?.refreshLibraryStats()
                // 仍然不替换 selectedItem——替换会诱发 AttributeGraph 无限重绘循环。
            }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    deinit {
        if let obs = updateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    public func loadAll() {
        reload()
        refreshLibraryStats()
    }

    /// 每页条数（滚动到底自动加载下一页）
    static let pageSize = 300
    /// 是否可能还有更多（上次取回的数量 == pageSize）
    @Published public var hasMore: Bool = false
    /// 中间层返回的不透明游标。前端只保存和回传，不解释其编码。
    private var nextCursor: String?

    /// reload 序号（最新者优先）：快速连续触发时旧查询结果直接丢弃
    private var reloadSeq = 0

    /// 重新加载（异步版，17:05 定案）：
    /// 原版在主线程同步跑 fetchContents(300行) + sidebarTree + 两组计数——
    /// 67k 行库上每次切文件夹/订阅源都按出风火轮（用户实测定位）。
    /// DB 查询放后台，@Published 回主线程写；reloadSeq 保证乱序归并以最新为准。
    public func reload() {
        reloadSeq += 1
        let seq = reloadSeq
        let query = contentQuery(cursor: nil)
        let library = library
        Task { [weak self] in
            do {
                let page = try await library.page(query)
                guard let self, self.reloadSeq == seq else { return }
                self.items = page.items
                self.nextCursor = page.nextCursor
                self.hasMore = page.nextCursor != nil
                // 修 P1-6：筛选变化（哪怕改排序）不再销毁正在读的文章——保留 selectedItem，
                // 用户继续读完当前篇，不因筛选/排序变化被关掉。
                // 全量重查后 DB 已权威——清空乐观已读标记（防与「标为未读」等操作打架）
                self.readMarks.removeAll()
            } catch {
                guard let self, self.reloadSeq == seq else { return }
                self.showToast(error.localizedDescription)
            }
        }
    }

    /// 左栏树和全局计数独立刷新，绝不再成为中栏翻页/切筛选的前置条件。
    private var statsSeq = 0
    private func refreshLibraryStats() {
        statsSeq += 1
        let seq = statsSeq
        let library = library
        Task { [weak self] in
            do {
                let snapshot = try await library.snapshot()
                guard let self, self.statsSeq == seq else { return }
                self.sidebarTree = snapshot.nodes
                self.apply(snapshot.counts)
            } catch {
                guard let self, self.statsSeq == seq else { return }
                self.showToast(error.localizedDescription)
            }
        }
    }

    private func apply(_ counts: LibraryCountsSnapshot) {
        totalCount = counts.total
        totalUnread = counts.unread
        totalPending = counts.pending
        totalPendingUnread = counts.pendingUnread
        totalExported = counts.exported
        totalExportedUnread = counts.exportedUnread
        articleCount = counts.articles
        articleUnread = counts.articleUnread
        podcastCount = counts.podcasts
        podcastUnread = counts.podcastUnread
        videoCount = counts.videos
        videoUnread = counts.videoUnread
    }

    /// 阅读栏写回后的权威状态。只替换轻量 read/star 字段，其余摘要内容保持不动。
    private func apply(_ state: ContentState) {
        if let index = items.firstIndex(where: { $0.id == state.contentID }) {
            items[index] = items[index].replacingState(
                isRead: state.isRead,
                isStarred: state.isStarred)
        }
        if let selectedItem, selectedItem.id == state.contentID {
            self.selectedItem = selectedItem.replacingState(
                isRead: state.isRead,
                isStarred: state.isStarred)
        }
        readMarks[state.contentID] = state.isRead
    }

    /// 单篇已读状态改变时直接修正内存计数。避免每点一篇都重新聚合全库。
    private func applyUnreadDelta(for item: ContentSummary, delta: Int) {
        guard delta != 0 else { return }
        totalUnread = max(0, totalUnread + delta)
        switch item.contentType {
        case "podcast": podcastUnread = max(0, podcastUnread + delta)
        case "video", "youtube": videoUnread = max(0, videoUnread + delta)
        default: articleUnread = max(0, articleUnread + delta)
        }
        if item.hasExport { totalExportedUnread = max(0, totalExportedUnread + delta) }
        if item.hasUnmetProcessing { totalPendingUnread = max(0, totalPendingUnread + delta) }
        guard let sourceID = item.sourceID else { return }
        sidebarTree = sidebarTree.map {
            Self.adjustingUnread(in: $0, sourceID: sourceID, delta: delta)
        }
    }

    private static func adjustingUnread(
        in node: LibraryNode,
        sourceID: Int64,
        delta: Int
    ) -> LibraryNode {
        if node.kind == .folder {
            let children = node.children.map {
                adjustingUnread(in: $0, sourceID: sourceID, delta: delta)
            }
            return LibraryNode(
                id: node.id, kind: node.kind, name: node.name, count: node.count,
                unread: children.reduce(0) { $0 + $1.unread },
                sourceID: node.sourceID, folderID: node.folderID, children: children)
        }
        guard node.sourceID == sourceID else { return node }
        return LibraryNode(
            id: node.id, kind: node.kind, name: node.name, count: node.count,
            unread: max(0, node.unread + delta),
            sourceID: node.sourceID, folderID: node.folderID, children: node.children)
    }

    /// 加载下一页（滚动到底触发）。追加而非替换。
    public func loadMore() {
        guard hasMore, let cursor = nextCursor else { return }
        let offset = items.count
        let query = contentQuery(cursor: cursor)
        let library = library
        Task { [weak self] in
            do {
                let page = try await library.page(query)
                guard let self, self.items.count == offset else { return }
                self.nextCursor = page.nextCursor
                self.hasMore = page.nextCursor != nil
                let existing = Set(self.items.map(\.id))
                self.items.append(contentsOf: page.items
                    .filter { !existing.contains($0.id) })
            } catch {
                self?.showToast(error.localizedDescription)
            }
        }
    }

    /// 左栏选中：nil=全部，"source_id=N" / "folder_id=N"
    public func selectFilter(_ filter: String?) {
        selectedFilter = filter
        reload()
    }

    /// 打开文章：选中并标已读，异步加载正文（列表是轻列，正文点开才查）
    public func open(_ item: ContentSummary) {
        let wasUnread = !item.isRead && canUpdateReadingState
        // 选中项立即出详情；未读则给阅读区一个已读实例（工具条已读态即时正确）。
        // 这只是个新实例，不碰 items 数组——表格数据纹丝不动。
        selectedItem = wasUnread
            ? item.replacingState(isRead: true, isStarred: item.isStarred)
            : item
        if wasUnread {
            let library = library
            // 幂等写入通过中间层完成；成功后只刷新左栏计数，不改写 items。
            Task { [weak self] in
                do {
                    _ = try await library.setRead(contentID: item.id, isRead: true)
                    guard let self else { return }
                    self.applyUnreadDelta(for: item, delta: -1)
                } catch {
                    guard let self else { return }
                    // 极少数写入失败时撤销详情区的乐观已读态。
                    if self.selectedItem?.id == item.id { self.selectedItem = item }
                    self.readMarks[item.id] = nil
                    self.showToast(error.localizedDescription)
                }
            }
            // ⚠️ 铁证：任何对 items（表格数据源）的改写——同步/0.3s 延迟——快速连点时
            // 都会落进渲染窗口 → reentrant → AG cycle → 闪退（watch5/7 对照实验）。
            // 已读标记走非结构性通道：readMarks 只影响行内颜色/圆点（表格结构纹丝不动），
            // 即便落在渲染窗口也只是"更新中发布"（丢一帧自愈），不会重入崩溃。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.readMarks[item.id] == nil else { return }
                self.readMarks[item.id] = true
            }
        }
    }

    /// 切换已读/未读
    public func toggleRead(_ item: ContentSummary) {
        guard canUpdateReadingState else {
            showToast("当前设备只有阅读权限")
            return
        }
        let targetRead = !effectiveIsRead(item)
        // 只改轻量覆盖字典，文章列表结构保持不变。
        readMarks[item.id] = targetRead
        let library = library
        Task { [weak self] in
            do {
                _ = try await library.setRead(contentID: item.id, isRead: targetRead)
                guard let self else { return }
                // “未读”筛选下标为已读会移出列表，必须重查；其他视图只更新左栏计数。
                self.applyUnreadDelta(for: item, delta: targetRead ? -1 : 1)
                if self.readFilter == .unread { self.reload() }
            } catch {
                guard let self else { return }
                self.readMarks[item.id] = nil
                self.showToast(error.localizedDescription)
            }
        }
    }

    /// 行内乐观状态优先于列表快照；供行样式和右键菜单共用。
    public func effectiveIsRead(_ item: ContentSummary) -> Bool {
        if let override = readMarks[item.id] { return override }
        if selectedItem?.id == item.id { return selectedItem?.isRead ?? item.isRead }
        return item.isRead
    }

    /// 切换星标
    public func toggleStar(_ item: ContentSummary) {
        guard canUpdateReadingState else {
            showToast("当前设备只有阅读权限")
            return
        }
        let newStarred = !item.isStarred
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            let current = items[index]
            items[index] = current.replacingState(
                isRead: effectiveIsRead(current), isStarred: newStarred)
        }
        if let selectedItem, selectedItem.id == item.id {
            self.selectedItem = selectedItem.replacingState(
                isRead: selectedItem.isRead, isStarred: newStarred)
        }
        let library = library
        Task { [weak self] in
            do {
                _ = try await library.setStarred(contentID: item.id, isStarred: newStarred)
            } catch {
                self?.showToast(error.localizedDescription)
                self?.reload()
            }
        }
    }

    // MARK: 轻提示（3s 自动消失）
    @Published public var toastMessage: String? = nil
    /// 已读乐观覆盖（非结构性）：true=已读、false=未读，ArticleRow 据此即时更新。
    /// 不碰 items（表格数据源），重载后 DB 已权威即清空。详见 open() 注释（watch5/7 对照实验）。
    @Published public var readMarks: [Int64: Bool] = [:]
    private var toastTask: Task<Void, Never>?
    public func showToast(_ msg: String) {
        toastMessage = msg
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toastMessage = nil
        }
    }

    /// 全部标已读（按当前筛选范围）。返回影响条数。
    public func markAllRead() {
        guard canUpdateReadingState else {
            showToast("当前设备只有阅读权限")
            return
        }
        let filter = contentFilter()
        let library = library
        Task { [weak self] in
            do {
                let summary = try await library.markRead(filter: filter)
                guard let self else { return }
                self.showToast("已标记 \(summary.affectedCount) 条为已读")
                self.reload()
                self.refreshLibraryStats()
            } catch {
                self?.showToast(error.localizedDescription)
            }
        }
    }

    private func contentQuery(cursor: String?) -> ContentQuery {
        ContentQuery(
            filter: contentFilter(),
            sort: ContentSort(rawValue: sortOrder.rawValue) ?? .newest,
            pageSize: Self.pageSize,
            cursor: cursor
        )
    }

    private func contentFilter() -> ContentFilter {
        let scoreBounds = Self.scoreBounds(minimum: minScore, maximum: maxScore)
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let processing = processedStates.compactMap { key, state -> ProcessingCriterion? in
            guard state != .none, let kind = ProcessingKind(rawValue: key) else { return nil }
            return ProcessingCriterion(
                kind: kind, match: state == .yes ? .complete : .incomplete)
        }.sorted { $0.kind.rawValue < $1.kind.rawValue }
        let contractReadState: ContentReadState = switch readFilter {
        case .all: .all
        case .unread: .unread
        case .starred: .starred
        }
        return ContentFilter(
            sourceID: selectedSourceId,
            folderID: selectedFolderId,
            category: selectedContentCategory.flatMap(ContentCategory.init(rawValue:)),
            minimumScore: scoreBounds.minimum,
            maximumScore: scoreBounds.maximum,
            includeUnscored: includeUnscored,
            readState: contractReadState,
            exportedOnly: selectedFilter == "exported",
            keyword: trimmedKeyword.isEmpty ? nil : trimmedKeyword,
            processing: processing,
            unmetProcessingOnly: pendingOnly
        )
    }

    /// 评分固定为 0...100。默认 0...100 不产生 SQL 条件；越界值先收敛，
    /// 下限高于上限时保留这个空区间，让列表明确显示 0 条而不是偷偷交换用户输入。
    nonisolated static func scoreBounds(minimum: Int, maximum: Int) -> (minimum: Int?, maximum: Int?) {
        let lower = Swift.min(100, Swift.max(0, minimum))
        let upper = Swift.min(100, Swift.max(0, maximum))
        return (lower > 0 ? lower : nil, upper < 100 ? upper : nil)
    }

    // MARK: 快捷键导航（搜索框聚焦时禁用，避免空格/j/k 被列表抢走）

    /// 选中下一篇
    public func selectNext() { guard !searchFocused else { return }; moveSelection(by: 1) }
    /// 选中上一篇
    public func selectPrev() { guard !searchFocused else { return }; moveSelection(by: -1) }

    /// 快捷键触发已读切换（空格）——搜索框聚焦时忽略
    public func shortcutToggleRead() {
        guard !searchFocused, let it = selectedItem else { return }
        toggleRead(it)
    }

    private func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        if let cur = selectedItem, let idx = items.firstIndex(where: { $0.id == cur.id }) {
            let next = max(0, min(items.count - 1, idx + delta))
            open(items[next])
        } else {
            open(delta > 0 ? items[0] : items[items.count - 1])
        }
    }

    public var canUpdateReadingState: Bool {
        permissions.allows(.updateReadingState, capability: .library)
    }
}


public extension LibraryNode {
    var isFolder: Bool { kind == .folder }

    var filterKey: String? {
        if let folderID { return "folder_id=\(folderID)" }
        if let sourceID { return "source_id=\(sourceID)" }
        return nil
    }
}
