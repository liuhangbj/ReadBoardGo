import SwiftUI
import WebKit
import QuartzCore
import ReadBoardContract
import ReadBoardFeatures
import ReadBoardSharedUI

public struct ContentView: View {
    private let services: ReadBoardServices
    @StateObject private var vm: ContentViewModel
    @StateObject private var sourceCatalog: SourceCatalogStore
    @EnvironmentObject private var appTab: AppTab
    @Environment(\.openSettings) private var openSettings
    @State private var issueCenter: ReadBoardIssueCenterModel
    @State private var showIssueCenter = false
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    public init(services: ReadBoardServices = .live) {
        self.services = services
        _vm = StateObject(wrappedValue: ContentViewModel(
            library: services.library,
            permissions: services.permissions))
        _sourceCatalog = StateObject(
            wrappedValue: SourceCatalogStore(gateway: services.sourceCatalog))
        _issueCenter = State(initialValue: ReadBoardIssueCenterModel(
            environment: services.featureEnvironment))
    }

    public var body: some View {
        NavigationSplitView {
            sourceSidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } content: {
            articleList
                .navigationSplitViewColumnWidth(min: 280, ideal: 380, max: 640)
        } detail: {
            readingPane
        }
        .navigationTitle("ReadBoard")
        .onAppear { vm.loadAll() }
        .background(shortcutHandlers)
        .overlay(alignment: .bottom) {
            if let toast = vm.toastMessage {
                Text(toast)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.rbText)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
                    .rbFloatingShadow()
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: vm.toastMessage)
        .sheet(isPresented: $showShortcutHelp) {
            ShortcutHelpView()
        }
        .sheet(isPresented: $showIssueCenter) {
            ReadBoardIssueCenterView(environment: services.featureEnvironment) { action in
                switch action {
                case .openSources: appTab.selection = 1
                case .openOperations: appTab.selection = 3
                case .openSettings(let route):
                    SettingsNavigationStore.shared.request(route)
                    openSettings()
                }
            }
        }
        .task {
            while !Task.isCancelled {
                if services.permissions.allows(.manageSources, capability: .sourceManagement) {
                    await sourceCatalog.refresh()
                }
                await issueCenter.refresh()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pipelinePendingUpdated)) { _ in
            Task { await issueCenter.refresh() }
        }
    }

    // MARK: 快捷键

    private var shortcutHandlers: some View {
        Group {
            Button("") { vm.selectNext() }.keyboardShortcut("j", modifiers: [])
            Button("") { vm.selectPrev() }.keyboardShortcut("k", modifiers: [])
            Button("") {
                if let item = vm.selectedItem { vm.toggleStar(item) }
            }.keyboardShortcut("s", modifiers: [])
            Button("") { vm.shortcutToggleRead() }.keyboardShortcut(.space, modifiers: [])
            Button("") { openOriginal() }.keyboardShortcut("v", modifiers: [])
            Button("") { vm.markAllRead() }.keyboardShortcut("e", modifiers: [])
            Button("") { showShortcutHelp = true }.keyboardShortcut("?", modifiers: [])
            Button("") { focusSearch() }.keyboardShortcut("f", modifiers: [])
        }
        .frame(width: 0, height: 0)
        .opacity(0)
    }

    @State private var showShortcutHelp = false

    private func focusSearch() {
        searchFocused = true
    }

    private func openOriginal() {
        guard let item = vm.selectedItem,
              let url = URL(string: item.url),
              !item.url.isEmpty else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: 左栏

    @State private var showAddSource = false
    @State private var showImportSummary = false
    @State private var importPlan: OPMLImportPlan?

    private var sourceSidebar: some View {
        ReadBoardLibrarySidebarView(
            model: vm,
            sourceCatalog: sourceCatalog,
            library: services.library,
            sourceManagement: services.sourceManagement,
            permissions: services.permissions,
            healthStatus: sharedHealthStatus,
            healthStatusText: issueCenter.statusText,
            onOpenIssueCenter: { showIssueCenter = true },
            onAddSource: { showAddSource = true },
            onImportOPML: { presentOPMLImporter() },
            onNavigate: { destination in
                switch destination {
                case .sources: appTab.selection = 1
                case .dashboard: appTab.selection = 3
                }
            })
            .sheet(isPresented: $showAddSource) {
                AddSourceSheet(
                    onboarding: services.sourceOnboarding,
                    sourceCatalog: services.sourceCatalog,
                    sourceManagement: services.sourceManagement)
                    .onDisappear {
                        vm.loadAll()
                        Task { await sourceCatalog.refresh() }
                    }
            }
            .sheet(isPresented: $showImportSummary) {
                if let plan = importPlan {
                    OPMLImportSummary(
                        plan: plan,
                        onboarding: services.sourceOnboarding,
                        sourceCatalog: services.sourceCatalog)
                        .onDisappear {
                            vm.loadAll()
                            Task { await sourceCatalog.refresh() }
                        }
                }
            }
    }

    private var sharedHealthStatus: ReadBoardSidebarHealthStatus {
        switch issueCenter.status {
        case .healthy: .healthy
        case .repairing: .repairing
        case .needsAttention: .needsAttention
        }
    }

    /// The file panel belongs to the macOS host; parsing and confirmation retain Core behavior.
    private func presentOPMLImporter() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择要导入的 OPML 文件（.opml 或 .xml）"
        NSApp.activate(ignoringOtherApps: true)
        guard let window = NSApp.mainWindow else {
            vm.toastMessage = "无法打开文件选择器（无活动窗口）"
            return
        }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            guard let xml = try? String(contentsOf: url, encoding: .utf8) else {
                DispatchQueue.main.async {
                    vm.toastMessage = "读取文件失败：\(url.lastPathComponent)"
                }
                return
            }
            DispatchQueue.main.async { vm.toastMessage = "解析中…" }
            DispatchQueue.global(qos: .userInitiated).async {
                let plan = OPMLService.shared.parseOPML(xml)
                DispatchQueue.main.async {
                    if let error = plan.parseError {
                        vm.toastMessage = "导入失败：\(error)"
                    } else if plan.outlines.isEmpty {
                        vm.toastMessage = "未从文件中解析到任何订阅源"
                    } else {
                        vm.toastMessage = nil
                        importPlan = plan
                        showImportSummary = true
                    }
                }
            }
        }
    }

    // MARK: 中栏

    private var articleList: some View {
        ReadBoardArticleListView(
            model: vm,
            processing: services.processing,
            export: services.export,
            permissions: services.permissions,
            searchFocused: $searchFocused)
    }

    // MARK: 右栏

    private var readingPane: some View {
        Group {
            if let item = vm.selectedItem {
                ReadingView(
                    item: item,
                    showTranslated: $vm.showTranslated,
                    library: services.library,
                    contentDetail: services.contentDetail,
                    mediaPlayback: services.mediaPlayback,
                    processing: services.processing,
                    export: services.export,
                    permissions: services.permissions,
                    onPrev: { vm.selectPrev() },
                    onNext: { vm.selectNext() })
                    .id(item.id)
            } else {
                ContentUnavailableView(
                    "选择一篇文章",
                    systemImage: "doc.text",
                    description: Text("共 \(vm.totalCount) 条内容"))
            }
        }
    }
}

extension Notification.Name {
    static let contentUpdated = Notification.Name("contentUpdated")
}

// MARK: - 快捷键帮助面板

struct ShortcutHelpView: View {
    @Environment(\.dismiss) private var dismiss

    private let groups: [(String, [(String, String)])] = [
        ("导航", [
            ("j / ↓", "下一篇"),
            ("k / ↑", "上一篇"),
            ("f", "聚焦搜索框"),
        ]),
        ("文章操作", [
            ("空格", "已读 / 未读切换"),
            ("s", "星标 / 取消星标"),
            ("e", "当前筛选范围全部标已读"),
            ("v", "浏览器打开原文"),
        ]),
        ("其他", [
            ("?", "显示本帮助"),
            ("⌘N", "添加订阅源"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("键盘快捷键")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.rbText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Color.rbText3)
                }
                .buttonStyle(.plain)
            }

            ForEach(groups, id: \.0) { group, rows in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(text: group)
                    ForEach(rows, id: \.0) { key, description in
                        HStack(spacing: 10) {
                            Text(key)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.rbText2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.rbSurface)
                                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.md))
                                .overlay(
                                    RoundedRectangle(cornerRadius: RB.Radius.md)
                                        .strokeBorder(
                                            Color.rbHairline,
                                            lineWidth: RB.Line.hair))
                                .frame(minWidth: 72, alignment: .center)
                            Text(description)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.rbText)
                            Spacer()
                        }
                    }
                }
            }

            Text("提示：搜索框聚焦时，j/k/空格 等单键快捷键自动禁用，避免与输入冲突。")
                .font(.system(size: 11))
                .foregroundStyle(Color.rbText3)
        }
        .padding(24)
        .frame(width: 430)
    }
}
