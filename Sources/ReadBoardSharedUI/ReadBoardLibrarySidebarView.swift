import ReadBoardContract
import SwiftUI

public enum ReadBoardSidebarHealthStatus: Sendable, Equatable {
    case healthy
    case repairing
    case needsAttention
}

public enum ReadBoardSidebarDestination: Sendable, Equatable {
    case sources
    case dashboard
}

/// The Core library sidebar copied into the shared UI boundary.
///
/// The view owns sidebar-only presentation state and calls contract gateways for mutations.
/// Host-owned screens (issue center and source onboarding) remain closures so Core and Go can
/// present the same sidebar while routing those destinations to their own scene container.
@MainActor
public struct ReadBoardLibrarySidebarView: View {
    @ObservedObject private var model: ContentViewModel
    @ObservedObject private var sourceCatalog: SourceCatalogStore

    private let library: any LibraryGateway
    private let sourceManagement: any SourceManagementGateway
    private let permissions: ReadBoardPermissionSet
    private let healthStatus: ReadBoardSidebarHealthStatus
    private let healthStatusText: String
    private let onOpenIssueCenter: () -> Void
    private let onAddSource: () -> Void
    private let onImportOPML: () -> Void
    private let onNavigate: (ReadBoardSidebarDestination) -> Void

    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1.0
    @State private var showAddFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: RenameTarget?
    @State private var renameInput = ""
    @State private var deleteSourceTarget: DeleteSourceTarget?
    @State private var expandedFolders: Set<String> = []
    @State private var pendingBackfill: PendingBackfill?
    @State private var initializedExpansion = false

    private static let expandedKey = "sidebar.expandedFolders"
    private static let fetchIntervals = [5, 15, 30, 60, 120, 360, 720]

    public init(
        model: ContentViewModel,
        sourceCatalog: SourceCatalogStore,
        library: any LibraryGateway,
        sourceManagement: any SourceManagementGateway,
        permissions: ReadBoardPermissionSet = .localFullControl,
        healthStatus: ReadBoardSidebarHealthStatus,
        healthStatusText: String,
        onOpenIssueCenter: @escaping () -> Void,
        onAddSource: @escaping () -> Void,
        onImportOPML: @escaping () -> Void,
        onNavigate: @escaping (ReadBoardSidebarDestination) -> Void
    ) {
        self.model = model
        self.sourceCatalog = sourceCatalog
        self.library = library
        self.sourceManagement = sourceManagement
        self.permissions = permissions
        self.healthStatus = healthStatus
        self.healthStatusText = healthStatusText
        self.onOpenIssueCenter = onOpenIssueCenter
        self.onAddSource = onAddSource
        self.onImportOPML = onImportOPML
        self.onNavigate = onNavigate
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            ReadBoardHairline()
            content
            ReadBoardHairline()
            footer
        }
        .background(ReadBoardDesign.C.bgSidebar)
        .alert("新建文件夹", isPresented: $showAddFolder) {
            TextField("文件夹名称", text: $newFolderName)
            Button("创建") { createFolder() }
            Button("取消", role: .cancel) { newFolderName = "" }
        } message: {
            Text("文件夹用于给订阅源分组（如「快讯」「深度」），并可批量设置组内内容处理选项。")
        }
        .alert("重命名", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("名称", text: $renameInput)
            Button("保存") { renameSelection() }
            Button("取消", role: .cancel) { renameTarget = nil }
        }
        .alert("永久删除订阅源？", isPresented: Binding(
            get: { deleteSourceTarget != nil },
            set: { if !$0 { deleteSourceTarget = nil } }
        )) {
            Button("取消", role: .cancel) { deleteSourceTarget = nil }
            Button("永久删除", role: .destructive) { deleteSelectedSource() }
        } message: {
            if let target = deleteSourceTarget {
                Text("将永久删除「\(target.name)」及其全部文章、AI 处理结果和应用内导出记录。此操作无法撤销；已经写入 Obsidian 的文件不会删除。")
            }
        }
        .alert("处理历史数据？", isPresented: Binding(
            get: { pendingBackfill != nil },
            set: { if !$0 { pendingBackfill = nil } }
        )) {
            Button(pendingBackfill?.action == .fulltext ? "重提所有历史全文" : "处理所有历史内容") {
                runPendingBackfill()
            }
            Button("只处理新增", role: .cancel) { pendingBackfill = nil }
        } message: {
            if let pending = pendingBackfill {
                if pending.action == .fulltext {
                    Text("「\(pending.name)」的全文提取模式已切换为\(pending.pipelineLabel)。\n\n• 重提历史：存量文章按新模式重新提取全文（耗时较长）\n• 只处理新增：历史不动，新抓的按新模式抓")
                } else {
                    Text("「\(pending.name)」的\(pending.pipelineLabel)已开启。\n\n• 处理历史：存量内容补做相应处理（耗时较长，按量计费）\n• 只处理新增：历史不动，新抓的自动进入内容处理引擎")
                }
            }
        }
        .onAppear { initializeExpandedFoldersIfNeeded() }
        .onChange(of: model.sidebarTree) { _, _ in
            initializeExpandedFoldersIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button(action: onOpenIssueCenter) {
                ZStack {
                    Circle()
                        .fill(healthColor.opacity(0.16))
                        .frame(width: 24, height: 24)
                    Image(systemName: healthIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(healthColor)
                }
            }
            .buttonStyle(.plain)
            .help("问题中心：\(healthStatusText)")

            ReadBoardSectionLabel(text: "订阅源")
            Spacer()
            if canManageSources {
                Button { showAddFolder = true } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 13))
                }
                .buttonStyle(ReadBoardQuietButtonStyle())
                .help("新建文件夹")

                Menu {
                    Button(action: onAddSource) {
                        Label("添加订阅源", systemImage: "plus")
                    }
                    Button(action: onImportOPML) {
                        Label("导入 OPML", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 13))
                }
                #if os(macOS)
                .menuStyle(.borderlessButton)
                #endif
                .buttonStyle(ReadBoardQuietButtonStyle())
                .help("添加订阅源 / 导入 OPML")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                fixedRow(
                    title: "全部文章", icon: "tray.full", filter: nil,
                    unread: model.totalUnread, total: model.totalCount)
                fixedRow(
                    title: "待处理", icon: "gearshape.2.fill", filter: "pending",
                    unread: model.totalPendingUnread, total: model.totalPending)
                fixedRow(
                    title: "已导出", icon: "square.and.arrow.up.fill", filter: "exported",
                    unread: model.totalExportedUnread, total: model.totalExported)

                sidebarDivider

                fixedRow(
                    title: "文章", icon: "doc.text.fill", filter: "ctype=article",
                    unread: model.articleUnread, total: model.articleCount, iconSize: 12)
                fixedRow(
                    title: "播客", icon: "mic.fill", filter: "ctype=podcast",
                    unread: model.podcastUnread, total: model.podcastCount, iconSize: 12)
                fixedRow(
                    title: "视频", icon: "play.rectangle.fill", filter: "ctype=video",
                    unread: model.videoUnread, total: model.videoCount, iconSize: 12)

                sidebarDivider

                ForEach(model.sidebarTree) { node in
                    if node.isFolder {
                        HStack(spacing: 0) {
                            Button { toggleFolderExpanded(node.id) } label: {
                                Image(systemName: expandedFolders.contains(node.id)
                                      ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(ReadBoardDesign.C.text3)
                                    .frame(width: 16, alignment: .center)
                            }
                            .buttonStyle(.plain)
                            sidebarRow(node, indent: 0, showChevronSlot: false)
                        }
                        if expandedFolders.contains(node.id) {
                            ForEach(node.children) { child in
                                sidebarRow(child, indent: 1, showChevronSlot: true)
                            }
                        }
                    } else {
                        sidebarRow(node, indent: 0, showChevronSlot: true)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if canManageSources {
                navigationButton(
                    icon: "dot.radiowaves.left.and.right",
                    label: "订阅管理",
                    destination: .sources)
            }
            if canManageOperations {
                navigationButton(
                    icon: "chart.bar.doc.horizontal",
                    label: "数据看板",
                    destination: .dashboard)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var healthColor: Color {
        switch healthStatus {
        case .healthy: ReadBoardDesign.C.scoreHigh
        case .repairing: ReadBoardDesign.C.scoreMid
        case .needsAttention: ReadBoardDesign.C.scoreLow
        }
    }

    private var healthIcon: String {
        switch healthStatus {
        case .healthy: "checkmark"
        case .repairing: "arrow.triangle.2.circlepath"
        case .needsAttention: "exclamationmark"
        }
    }

    private func navigationButton(
        icon: String,
        label: String,
        destination: ReadBoardSidebarDestination
    ) -> some View {
        Button { onNavigate(destination) } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 12))
                    Text(label)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                Image(systemName: icon).font(.system(size: 12))
            }
            .foregroundStyle(ReadBoardDesign.C.text2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(ReadBoardRowHoverButtonStyle())
        .help("打开「\(label)」页面")
    }

    private func fixedRow(
        title: String,
        icon: String,
        filter: String?,
        unread: Int,
        total: Int,
        iconSize: CGFloat? = nil
    ) -> some View {
        let active = model.selectedFilter == filter
        return Button { model.selectFilter(filter) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(iconSize.map { .system(size: $0) })
                    .foregroundStyle(ReadBoardDesign.C.accent)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: ReadBoardDesign.F.sidebar * uiFontScale))
                    .foregroundStyle(ReadBoardDesign.C.text)
                    .lineLimit(1)
                Spacer()
                sidebarCount(unread: unread, total: total)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.vertical, 5 * uiFontScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .readBoardSelection(active)
        }
        .buttonStyle(ReadBoardRowHoverButtonStyle())
    }

    private var sidebarDivider: some View {
        ReadBoardHairline()
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
    }

    private func sidebarCount(unread: Int, total: Int) -> some View {
        ViewThatFits(in: .horizontal) {
            sidebarCountPair(unread: "\(unread)", total: "\(total)", hasUnread: unread > 0)
            sidebarCountPair(
                unread: ReadBoardSidebarFormatting.compactCount(unread),
                total: ReadBoardSidebarFormatting.compactCount(total),
                hasUnread: unread > 0)
        }
        .monospacedDigit()
        .lineLimit(1)
        .frame(minWidth: 44, idealWidth: 80, maxWidth: 96, alignment: .trailing)
        .layoutPriority(2)
        .accessibilityLabel("未读 \(unread)，全部 \(total)")
    }

    private func sidebarCountPair(unread: String, total: String, hasUnread: Bool) -> some View {
        HStack(spacing: 1) {
            Text(unread)
                .font(.system(
                    size: ReadBoardDesign.F.count * uiFontScale,
                    weight: hasUnread ? .medium : .regular))
                .foregroundStyle(hasUnread
                    ? ReadBoardDesign.C.accent : ReadBoardDesign.C.text3)
            Text("/\(total)")
                .font(.system(size: ReadBoardDesign.F.count * uiFontScale))
                .foregroundStyle(ReadBoardDesign.C.text3)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func sidebarRow(
        _ node: LibraryNode,
        indent: Int,
        showChevronSlot: Bool
    ) -> some View {
        let selected = model.selectedFilter == node.filterKey
        return Button { model.selectFilter(node.filterKey) } label: {
            HStack(spacing: 6) {
                if showChevronSlot {
                    Spacer().frame(width: 16)
                }
                if node.isFolder {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(ReadBoardDesign.C.text3)
                        .frame(width: 16)
                }
                Text(node.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: ReadBoardDesign.F.sidebar * uiFontScale))
                    .foregroundStyle(ReadBoardDesign.C.text)
                Spacer()
                sidebarCount(unread: node.unread, total: node.count)
            }
            .padding(.leading, node.isFolder ? 0 : (indent > 0 ? 6 : 0))
            .padding(.trailing, 10)
            .padding(.vertical, 5 * uiFontScale)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .readBoardSelection(selected)
        }
        .buttonStyle(ReadBoardRowHoverButtonStyle())
        .contextMenu {
            if canManageSources { sidebarContextMenu(node) }
        }
    }

    @ViewBuilder
    private func sidebarContextMenu(_ node: LibraryNode) -> some View {
        if let sourceID = node.sourceID {
            Button {
                renameTarget = RenameTarget(kind: .source, id: sourceID, name: node.name)
                renameInput = node.name
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button { Task { await refresh(scope: .init(kind: .source, id: sourceID)) } } label: {
                Label("立即刷新", systemImage: "arrow.clockwise")
            }
            Button { markRead(filter: ContentFilter(sourceID: sourceID)) } label: {
                Label("全部标为已读", systemImage: "checkmark.circle")
            }
            Divider()
            if let source = sourceCatalog.sources.first(where: { $0.id == sourceID }) {
                Menu {
                    pipelineToggleMenu(source: source)
                } label: {
                    Label("内容处理", systemImage: "gearshape.2")
                }
                Menu {
                    fetchSettingsMenu(source: source)
                } label: {
                    Label("抓取设置", systemImage: "arrow.down.circle")
                }
                Button {
                    Task {
                        _ = try? await sourceManagement.refetchFulltext(
                            scope: SourceScope(kind: .source, id: sourceID),
                            fullHistory: true)
                    }
                } label: {
                    Label("重新提取全文", systemImage: "arrow.triangle.2.circlepath")
                }
                Divider()
                Menu {
                    Button("无文件夹") { assignSource(sourceID, folderID: nil) }
                    ForEach(sourceCatalog.folders) { folder in
                        Button(folder.name) { assignSource(sourceID, folderID: folder.id) }
                    }
                } label: {
                    Label("移动到文件夹", systemImage: "folder")
                }
                Divider()
                Button(role: .destructive) {
                    deleteSourceTarget = DeleteSourceTarget(id: sourceID, name: source.name)
                } label: {
                    Label("永久删除此源", systemImage: "trash")
                }
            }
        } else if let folderID = node.folderID {
            Button {
                renameTarget = RenameTarget(kind: .folder, id: folderID, name: node.name)
                renameInput = node.name
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button { Task { await refresh(scope: .init(kind: .folder, id: folderID)) } } label: {
                Label("立即刷新全部", systemImage: "arrow.clockwise")
            }
            Button { markRead(filter: ContentFilter(folderID: folderID)) } label: {
                Label("全部标为已读", systemImage: "checkmark.circle")
            }
            Divider()
            if let folder = sourceCatalog.folders.first(where: { $0.id == folderID }) {
                Menu {
                    folderPipelineMenu(folder: folder)
                } label: {
                    Label("内容处理", systemImage: "gearshape.2")
                }
            }
            Menu {
                folderFetchSettingsMenu(folderID: folderID)
            } label: {
                Label("抓取设置", systemImage: "arrow.down.circle")
            }
            Button {
                Task {
                    _ = try? await sourceManagement.refetchFulltext(
                        scope: SourceScope(kind: .folder, id: folderID),
                        fullHistory: true)
                }
            } label: {
                Label("重新提取全文", systemImage: "arrow.triangle.2.circlepath")
            }
            Divider()
            Button(role: .destructive) {
                Task {
                    _ = try? await sourceManagement.remove(
                        scope: SourceScope(kind: .folder, id: folderID))
                    await reloadAfterMutation()
                }
            } label: {
                Label("删除文件夹", systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func pipelineToggleMenu(source: SourceCatalogItem) -> some View {
        Button {
            Task {
                _ = try? await sourceManagement.backfillProcessing(
                    scope: SourceScope(kind: .source, id: source.id), key: nil)
            }
        } label: {
            Label("重新处理本源全部", systemImage: "arrow.triangle.2.circlepath")
        }
        Divider()
        pipelineMenuItem("AI 评分", key: .score, enabled: source.policy.autoScore, source: source)
        pipelineMenuItem("AI 翻译", key: .translate, enabled: source.policy.autoTranslate, source: source)
        pipelineMenuItem("AI 摘要", key: .summarize, enabled: source.policy.autoSummarize, source: source)
        if source.transcribable {
            pipelineMenuItem(
                "AI 转录", key: .transcribe,
                enabled: source.policy.autoTranscribe, source: source)
        }
    }

    private func pipelineMenuItem(
        _ label: String,
        key: SourcePolicyKey,
        enabled: Bool,
        source: SourceCatalogItem
    ) -> some View {
        Button {
            let turningOn = !enabled
            Task {
                try? await sourceManagement.setPolicy(
                    scope: SourceScope(kind: .source, id: source.id),
                    key: key,
                    enabled: turningOn)
                await sourceCatalog.refresh()
            }
            if turningOn {
                pendingBackfill = PendingBackfill(
                    kind: .source,
                    id: source.id,
                    name: source.name,
                    pipelineLabel: label,
                    action: .pipeline,
                    policyKey: key)
            }
        } label: {
            checkmarkMenuLabel(label, checked: enabled)
        }
    }

    @ViewBuilder
    private func fetchSettingsMenu(source: SourceCatalogItem) -> some View {
        Menu("提取全文：\(source.fetchModeAutomatic ? "自动（\(fetchModeName(source.fetchMode, source: source))）" : fetchModeName(source.fetchMode, source: source))") {
            Button {
                setFetchMode(.automatic, scope: .init(kind: .source, id: source.id))
            } label: {
                HStack {
                    Image(systemName: source.fetchModeAutomatic
                          ? "checkmark" : "arrow.triangle.2.circlepath")
                    Text("自动（\(fetchModeName(source.fetchMode, source: source))）")
                }
            }
            Button("重新检测") {
                Task {
                    try? await sourceManagement.redetectFetchMode(
                        scope: SourceScope(kind: .source, id: source.id))
                    await sourceCatalog.refresh()
                }
            }
            Divider()
            ForEach(fetchModes(for: source), id: \.rawValue) { mode in
                Button {
                    setFetchMode(mode, scope: .init(kind: .source, id: source.id))
                } label: {
                    checkmarkMenuLabel(
                        fetchModeName(mode, source: source),
                        checked: !source.fetchModeAutomatic && source.fetchMode == mode)
                }
            }
        }
        Menu("抓取频率：\(intervalLabel(source.fetchIntervalMinutes))") {
            ForEach(Self.fetchIntervals, id: \.self) { minutes in
                Button {
                    setFetchInterval(minutes, scope: .init(kind: .source, id: source.id))
                } label: {
                    checkmarkMenuLabel(
                        intervalMenuLabel(minutes),
                        checked: source.fetchIntervalMinutes == minutes)
                }
            }
        }
    }

    @ViewBuilder
    private func folderFetchSettingsMenu(folderID: Int64) -> some View {
        let uniformMode = ReadBoardSidebarCatalogSummary.uniformFetchMode(
            sourceCatalog.sources(inFolder: folderID))
        let uniformInterval = ReadBoardSidebarCatalogSummary.uniformInterval(
            sourceCatalog.sources(inFolder: folderID))

        Menu("提取全文：\(folderFetchModeLabel(uniformMode))") {
            Button {
                setFetchMode(.automatic, scope: .init(kind: .folder, id: folderID))
            } label: {
                HStack {
                    Image(systemName: uniformMode?.kind == .automatic
                          ? "checkmark" : "arrow.triangle.2.circlepath")
                    Text("自动\(uniformMode?.kind == .automatic && uniformMode?.mode != nil ? "（\(uniformMode!.mode!.sidebarDisplayName)）" : "")")
                }
            }
            Button("重新检测") {
                Task {
                    try? await sourceManagement.redetectFetchMode(
                        scope: SourceScope(kind: .folder, id: folderID))
                    await sourceCatalog.refresh()
                }
            }
            Divider()
            ForEach(SourceFetchMode.allCases.filter(\.sidebarIsUserSelectable), id: \.rawValue) { mode in
                Button {
                    setFetchMode(mode, scope: .init(kind: .folder, id: folderID))
                } label: {
                    checkmarkMenuLabel(
                        mode.sidebarDisplayName,
                        checked: uniformMode?.kind == .manual && uniformMode?.mode == mode)
                }
            }
            Divider()
            Button {} label: {
                checkmarkMenuLabel("按订阅源设置", checked: uniformMode == nil)
            }
            .disabled(true)
        }

        Menu("抓取频率：\(uniformInterval.map(intervalLabel) ?? "按订阅源设置")") {
            ForEach(Self.fetchIntervals, id: \.self) { minutes in
                Button {
                    setFetchInterval(minutes, scope: .init(kind: .folder, id: folderID))
                } label: {
                    checkmarkMenuLabel(
                        intervalMenuLabel(minutes),
                        checked: uniformInterval == minutes)
                }
            }
            Divider()
            Button {} label: {
                checkmarkMenuLabel("按订阅源设置", checked: uniformInterval == nil)
            }
            .disabled(true)
        }
    }

    @ViewBuilder
    private func folderPipelineMenu(folder: SourceFolderItem) -> some View {
        Button {
            Task {
                _ = try? await sourceManagement.backfillProcessing(
                    scope: SourceScope(kind: .folder, id: folder.id), key: nil)
            }
        } label: {
            Label("重新处理本夹全部", systemImage: "arrow.triangle.2.circlepath")
        }
        Divider()
        folderPipelineItem("AI 评分", key: .score, folder: folder)
        folderPipelineItem("AI 翻译", key: .translate, folder: folder)
        folderPipelineItem("AI 摘要", key: .summarize, folder: folder)
        folderPipelineItem("AI 转录", key: .transcribe, folder: folder)
    }

    private func folderPipelineItem(
        _ label: String,
        key: SourcePolicyKey,
        folder: SourceFolderItem
    ) -> some View {
        let uniform = ReadBoardSidebarCatalogSummary.uniformPolicy(
            sourceCatalog.sources(inFolder: folder.id), key: key)
        let enabled = uniform ?? false
        return Button {
            let turningOn = !enabled
            Task {
                try? await sourceManagement.setPolicy(
                    scope: SourceScope(kind: .folder, id: folder.id),
                    key: key,
                    enabled: turningOn)
                await sourceCatalog.refresh()
            }
            if turningOn {
                pendingBackfill = PendingBackfill(
                    kind: .folder,
                    id: folder.id,
                    name: folder.name,
                    pipelineLabel: label,
                    action: .pipeline,
                    policyKey: key)
            }
        } label: {
            if uniform == nil {
                checkmarkMenuLabel("\(label)（按订阅源设置）", checked: false)
            } else {
                checkmarkMenuLabel(label, checked: enabled)
            }
        }
    }

    private func checkmarkMenuLabel(_ title: String, checked: Bool) -> some View {
        HStack {
            if checked {
                Image(systemName: "checkmark")
                    .frame(width: 12)
            } else {
                Color.clear
                    .frame(width: 12, height: 1)
            }
            Text(title)
        }
    }

    private func initializeExpandedFoldersIfNeeded() {
        guard !initializedExpansion else { return }
        if let saved = UserDefaults.standard.array(forKey: Self.expandedKey) as? [String] {
            expandedFolders = Set(saved)
            initializedExpansion = true
        } else if model.sidebarTree.contains(where: \.isFolder) {
            expandedFolders = Set(model.sidebarTree.filter(\.isFolder).map(\.id))
            initializedExpansion = true
        }
    }

    private func toggleFolderExpanded(_ id: String) {
        if expandedFolders.contains(id) {
            expandedFolders.remove(id)
        } else {
            expandedFolders.insert(id)
        }
        UserDefaults.standard.set(Array(expandedFolders), forKey: Self.expandedKey)
        initializedExpansion = true
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        newFolderName = ""
        guard !name.isEmpty else { return }
        Task {
            do {
                _ = try await sourceManagement.createFolder(name: name)
                await reloadAfterMutation()
            } catch {
                model.showToast(error.localizedDescription)
            }
        }
    }

    private func renameSelection() {
        let name = renameInput.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, let target = renameTarget else {
            renameTarget = nil
            return
        }
        renameTarget = nil
        Task {
            do {
                _ = try await sourceManagement.rename(
                    scope: SourceScope(kind: target.kind, id: target.id), name: name)
                await reloadAfterMutation()
            } catch {
                model.showToast(error.localizedDescription)
            }
        }
    }

    private func deleteSelectedSource() {
        guard let target = deleteSourceTarget else { return }
        deleteSourceTarget = nil
        Task {
            do {
                let result = try await sourceManagement.remove(
                    scope: SourceScope(kind: .source, id: target.id))
                if model.selectedItem?.sourceID == target.id { model.selectedItem = nil }
                if model.selectedFilter == "source_id=\(target.id)" { model.selectedFilter = nil }
                await reloadAfterMutation()
                model.showToast("已删除「\(target.name)」及其 \(result.affectedCount) 条内容")
            } catch {
                model.showToast(error.localizedDescription)
            }
        }
    }

    private func assignSource(_ sourceID: Int64, folderID: Int64?) {
        Task {
            do {
                try await sourceManagement.assignSource(sourceID: sourceID, folderID: folderID)
                await reloadAfterMutation()
            } catch {
                model.showToast(error.localizedDescription)
            }
        }
    }

    private func refresh(scope: SourceScope) async {
        do {
            _ = try await sourceManagement.sync(scope: scope)
            await reloadAfterMutation()
        } catch {
            model.showToast(error.localizedDescription)
        }
    }

    private func markRead(filter: ContentFilter) {
        Task {
            do {
                _ = try await library.markRead(filter: filter)
                model.loadAll()
            } catch {
                model.showToast(error.localizedDescription)
            }
        }
    }

    private func setFetchMode(_ mode: SourceFetchMode, scope: SourceScope) {
        Task {
            do {
                try await sourceManagement.setFetchMode(scope: scope, mode: mode)
                await sourceCatalog.refresh()
            } catch {
                model.showToast(error.localizedDescription)
            }
        }
    }

    private func setFetchInterval(_ minutes: Int, scope: SourceScope) {
        Task {
            do {
                try await sourceManagement.setFetchInterval(scope: scope, minutes: minutes)
                await sourceCatalog.refresh()
            } catch {
                model.showToast(error.localizedDescription)
            }
        }
    }

    private func runPendingBackfill() {
        guard let pending = pendingBackfill else { return }
        pendingBackfill = nil
        Task {
            let scope = SourceScope(kind: pending.kind, id: pending.id)
            do {
                switch pending.action {
                case .fulltext:
                    _ = try await sourceManagement.refetchFulltext(
                        scope: scope, fullHistory: false)
                case .pipeline:
                    _ = try await sourceManagement.backfillProcessing(
                        scope: scope, key: pending.policyKey)
                }
            } catch {
                model.showToast(error.localizedDescription)
            }
        }
    }

    private func reloadAfterMutation() async {
        await sourceCatalog.refresh()
        model.loadAll()
    }

    private func fetchModes(for source: SourceCatalogItem) -> [SourceFetchMode] {
        let modes = source.availableFetchModes.filter(\.sidebarIsUserSelectable)
        return modes.isEmpty
            ? SourceFetchMode.allCases.filter(\.sidebarIsUserSelectable)
            : modes
    }

    private func fetchModeName(
        _ mode: SourceFetchMode,
        source: SourceCatalogItem
    ) -> String {
        if mode == .externalFulltext, let name = source.fulltextDisplayName {
            return name
        }
        return mode.sidebarDisplayName
    }

    private func folderFetchModeLabel(
        _ uniform: ReadBoardSidebarCatalogSummary.UniformFetchMode?
    ) -> String {
        guard let uniform else { return "按订阅源设置" }
        switch uniform.kind {
        case .automatic:
            return uniform.mode.map { "自动（\($0.sidebarDisplayName)）" } ?? "自动"
        case .manual:
            return uniform.mode?.sidebarDisplayName ?? "手动"
        case .off:
            return "仅摘要"
        }
    }

    private func intervalLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)分钟" : "\(minutes / 60)小时"
    }

    private func intervalMenuLabel(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时"
    }

    private var canManageSources: Bool {
        permissions.allows(.manageSources, capability: .sourceManagement)
    }

    private var canManageOperations: Bool {
        permissions.allows(.manageOperations, capability: .administration)
    }
}

private extension ReadBoardLibrarySidebarView {
    struct RenameTarget {
        let kind: SourceScopeKind
        let id: Int64
        let name: String
    }

    struct DeleteSourceTarget {
        let id: Int64
        let name: String
    }

    struct PendingBackfill {
        enum Action { case pipeline, fulltext }

        let kind: SourceScopeKind
        let id: Int64
        let name: String
        let pipelineLabel: String
        let action: Action
        let policyKey: SourcePolicyKey?
    }
}

enum ReadBoardSidebarFormatting {
    static func compactCount(_ count: Int) -> String {
        guard count >= 10_000 else { return String(count) }
        let value = Double(count) / 10_000
        return value >= 10
            ? String(format: "%.0f万", value)
            : String(format: "%.1f万", value)
    }
}

enum ReadBoardSidebarCatalogSummary {
    enum FetchModeKind: Equatable { case automatic, manual, off }

    struct UniformFetchMode: Equatable {
        let kind: FetchModeKind
        let mode: SourceFetchMode?
    }

    static func uniformInterval(_ sources: [SourceCatalogItem]) -> Int? {
        guard let first = sources.first?.fetchIntervalMinutes else { return nil }
        return sources.allSatisfy { $0.fetchIntervalMinutes == first } ? first : nil
    }

    static func uniformFetchMode(_ sources: [SourceCatalogItem]) -> UniformFetchMode? {
        guard !sources.isEmpty else { return nil }
        if sources.allSatisfy(\.fetchModeAutomatic), let first = sources.first?.fetchMode,
           sources.allSatisfy({ $0.fetchMode == first }) {
            return UniformFetchMode(kind: .automatic, mode: first)
        }
        if sources.allSatisfy({ !$0.fetchModeAutomatic }), let first = sources.first?.fetchMode,
           sources.allSatisfy({ $0.fetchMode == first }) {
            return UniformFetchMode(kind: .manual, mode: first)
        }
        if sources.allSatisfy({ $0.fetchMode == .summary }) {
            return UniformFetchMode(kind: .off, mode: nil)
        }
        return nil
    }

    static func uniformPolicy(
        _ sources: [SourceCatalogItem],
        key: SourcePolicyKey
    ) -> Bool? {
        let values = sources.map { source in
            switch key {
            case .score: source.policy.autoScore
            case .translate: source.policy.autoTranslate
            case .summarize: source.policy.autoSummarize
            case .transcribe: source.policy.autoTranscribe
            }
        }
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }
}

private extension SourceFetchMode {
    var sidebarDisplayName: String {
        switch self {
        case .automatic: "自动"
        case .feedFull: "feed 自带全文"
        case .defuddle: "defuddle 本地"
        case .youtubeSubtitle: "YouTube字幕提取"
        case .bilibiliSubtitle: "BiliBili 字幕提取"
        case .externalFulltext: "平台内置全文提取"
        case .summary: "仅摘要"
        }
    }

    var sidebarIsUserSelectable: Bool {
        switch self {
        case .feedFull, .defuddle, .summary: true
        case .automatic, .youtubeSubtitle, .bilibiliSubtitle, .externalFulltext: false
        }
    }
}
