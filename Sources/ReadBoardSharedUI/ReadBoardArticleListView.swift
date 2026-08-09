#if os(macOS)
import AppKit
import SwiftUI
import ReadBoardContract

public struct ReadBoardArticleListView: View {
    @ObservedObject private var model: ContentViewModel
    private let processing: any ProcessingGateway
    private let export: any ExportGateway
    private let permissions: ReadBoardPermissionSet
    private let searchFocused: FocusState<Bool>.Binding

    @AppStorage("reading.uiFontScale") private var uiFontScale: Double = 1.0
    @AppStorage("list.density") private var listDensity: String = "comfortable"
    @AppStorage("list.showSource") private var listShowSource: Bool = true
    @AppStorage("list.showDate") private var listShowDate: Bool = true
    @AppStorage("list.unreadBold") private var listUnreadBold: Bool = true
    @AppStorage("list.dateFormat") private var listDateFormat: String = "absolute"

    public init(
        model: ContentViewModel,
        processing: any ProcessingGateway,
        export: any ExportGateway,
        permissions: ReadBoardPermissionSet = .localFullControl,
        searchFocused: FocusState<Bool>.Binding
    ) {
        self.model = model
        self.processing = processing
        self.export = export
        self.permissions = permissions
        self.searchFocused = searchFocused
    }

    public var body: some View {
        articleList
    }

    /// 筛选 chip（纸墨胶囊：激活墨蓝浅底+描边，未激活 surface+hairline）
    /// 三态筛选 chip：.none 不筛选（surface 底）/ .yes 已处理（实色）/ .no 未处理（淡粉）
    private func filterChip(label: String, state: ContentViewModel.ProcessedState,
                            action: @escaping () -> Void) -> some View {
        let (bg, fg, border): (Color, Color, Color) = {
            switch state {
            case .yes:  return (ReadBoardDesign.C.accent.opacity(0.14), ReadBoardDesign.C.accent, ReadBoardDesign.C.accent.opacity(0.35))
            case .no:   return (Color.pink.opacity(0.16), Color.pink, Color.pink.opacity(0.40))
            case .none: return (ReadBoardDesign.C.surface, ReadBoardDesign.C.text2, ReadBoardDesign.C.hairline)
            }
        }()
        return Button(action: action) {
            Text(label)
                .font(.system(size: 11))
                .padding(.horizontal, 8).padding(.vertical, 3.5)
                .background(bg)
                .foregroundStyle(fg)
                .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md)
                        .strokeBorder(border, lineWidth: ReadBoardDesign.Line.hair)
                )
        }
        .buttonStyle(.plain)
    }

    /// 处理状态三态按钮：none→已处理(实色 yes)→未处理(淡粉 no)→none
    private func processedToggle(key: String, label: String) -> some View {
        let state = model.processedStates[key] ?? .none
        return filterChip(label: label, state: state) {
            let next = state.next
            if next == .none { model.processedStates.removeValue(forKey: key) }
            else { model.processedStates[key] = next }
            model.reload()
        }
    }

    private var scoreFilterControls: some View {
        HStack(spacing: 5) {
            Text("评分")
                .font(.system(size: 11))
                .foregroundStyle(ReadBoardDesign.C.text3)
            scoreField(placeholder: "0", value: $model.minScore)
            Text("–")
                .font(.system(size: 11))
                .foregroundStyle(ReadBoardDesign.C.text3)
            scoreField(placeholder: "100", value: $model.maxScore)
            if model.minScore > 0 || model.maxScore < 100 {
                filterChip(label: "含未评分", state: model.includeUnscored ? .yes : .none) {
                    model.includeUnscored.toggle()
                    model.reload()
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func scoreField(placeholder: String, value: Binding<Int>) -> some View {
        TextField(placeholder, value: value, format: .number)
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .multilineTextAlignment(.trailing)
            .frame(width: 30)
            .padding(.horizontal, 6)
            .padding(.vertical, 3.5)
            .background(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md).fill(ReadBoardDesign.C.surface))
            .overlay(
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md)
                    .strokeBorder(ReadBoardDesign.C.hairline, lineWidth: ReadBoardDesign.Line.hair)
            )
            .onSubmit { model.reload() }
            .onChange(of: value.wrappedValue) { _, _ in model.reloadDebounced() }
    }

    private var readAndSortControls: some View {
        HStack(spacing: 8) {
            ReadBoardSegmented(
                items: ContentViewModel.ReadFilter.allCases.map { ($0, $0.display) },
                selection: $model.readFilter
            )
            .onChange(of: model.readFilter) { _, _ in model.reload() }

            Menu {
                ForEach(ContentViewModel.SortOrder.allCases) { order in
                    Button { model.sortOrder = order } label: {
                        HStack {
                            if model.sortOrder == order {
                                Image(systemName: "checkmark").frame(width: 12)
                            } else {
                                Color.clear.frame(width: 12, height: 1)
                            }
                            Text(order.display)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 9))
                        .foregroundStyle(ReadBoardDesign.C.text3)
                    Text(model.sortOrder.display)
                        .font(.system(size: 11))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(ReadBoardDesign.C.text3)
                }
                .foregroundStyle(ReadBoardDesign.C.text2)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(ReadBoardDesign.C.surface))
                .overlay(Capsule().strokeBorder(ReadBoardDesign.C.hairline, lineWidth: ReadBoardDesign.Line.hair))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .onChange(of: model.sortOrder) { _, _ in model.reload() }
        }
    }

    private var articleList: some View {
        VStack(spacing: 0) {
            // 搜索框（胶囊输入：surface 底 + hairline 描边，聚焦转墨蓝）
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(ReadBoardDesign.C.text3)
                    .font(.system(size: 12))
                TextField("搜索标题 / 正文", text: $model.keyword)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused(searchFocused)
                    .onChange(of: searchFocused.wrappedValue) { _, focused in model.searchFocused = focused }
                    .onChange(of: model.keyword) { _, _ in model.reloadDebounced() }
                if !model.keyword.isEmpty {
                    Button { model.keyword = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(ReadBoardDesign.C.text3)
                    }
                    .buttonStyle(.plain)
                }
            }
            .readBoardFieldBackground(focused: searchFocused.wrappedValue)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // 筛选条行1：宽栏同排；窄栏自动拆成“评分区间 / 阅读状态+排序”两行。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    scoreFilterControls
                    Spacer(minLength: 8)
                    readAndSortControls
                }
                VStack(alignment: .leading, spacing: 6) {
                    scoreFilterControls
                    HStack(spacing: 8) {
                        readAndSortControls
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 筛选条行2：处理状态平铺三态按钮（AI 评分/AI 摘要/AI 翻译/AI 转录，可多选）
            // 三态：无底色=不筛选 → 实色=已处理 → 淡粉=未处理，点击循环切换
            ReadBoardFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                Text("处理")
                    .font(.system(size: 11))
                    .foregroundStyle(ReadBoardDesign.C.text3)
                processedToggle(key: "fulltext", label: "全文提取")
                processedToggle(key: "score", label: "AI 评分")
                processedToggle(key: "summary", label: "AI 摘要")
                processedToggle(key: "translate", label: "AI 翻译")
                processedToggle(key: "transcribe", label: "AI 转录")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            ReadBoardHairline()

            // 操作条：计数 + 全部标已读
            HStack {
                ReadBoardSectionLabel(text: "\(model.items.count) 条")
                Spacer()
                if canUpdateReadingState {
                    Button {
                        model.markAllRead()
                    } label: {
                        Label("全部已读", systemImage: "checkmark.circle")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .buttonStyle(ReadBoardQuietButtonStyle())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            List(selection: Binding<Int64?>(
                get: { model.selectedItem?.id },
                // 只把稳定 id 交给 List；完整摘要由共享 Store 持有，避免大结构参与 Hash。
                set: { contentID in
                    guard let contentID,
                          let item = model.items.first(where: { $0.id == contentID }) else { return }
                    model.open(item)
                }
            )) {
                ForEach(model.items) { item in
                    ArticleRow(item: item, isSelected: model.selectedItem?.id == item.id,
                               isReadOverride: model.readMarks[item.id],
                               scale: uiFontScale,
                               density: listDensity, showSource: listShowSource,
                               showDate: listShowDate, unreadBold: listUnreadBold,
                               dateFormat: listDateFormat)
                        .tag(item.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 3, leading: 8, bottom: 3, trailing: 8))
                        .contextMenu {
                            // ── 状态操作 ──
                            if canUpdateReadingState {
                                Button { model.toggleRead(item) } label: {
                                    Label(model.effectiveIsRead(item) ? "标为未读" : "标为已读",
                                          systemImage: model.effectiveIsRead(item) ? "envelope.badge" : "envelope.open")
                                }
                                Button { model.toggleStar(item) } label: {
                                    Label(item.isStarred ? "取消星标" : "加星标",
                                          systemImage: item.isStarred ? "star.slash" : "star")
                                }
                                Divider()
                            }

                            // ── 打开 / 复制 ──
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(item.url, forType: .string)
                            } label: {
                                Label("复制链接", systemImage: "link")
                            }
                            Button {
                                if let url = URL(string: item.url), !item.url.isEmpty {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Label("浏览器打开原文", systemImage: "safari")
                            }

                            if canRunProcessing {
                                Divider()
                                Menu {
                                    Button {
                                        reprocessItem(item: item)
                                    } label: {
                                        Label("重新处理", systemImage: "arrow.triangle.2.circlepath")
                                    }
                                    Divider()
                                    Button {
                                        runPipelineForItem(item: item, type: "score")
                                    } label: {
                                        Label("AI 评分", systemImage: "star")
                                    }
                                    Button {
                                        runPipelineForItem(item: item, type: "summarize")
                                    } label: {
                                        Label("AI 摘要", systemImage: "text.quote")
                                    }
                                    Button {
                                        runPipelineForItem(item: item, type: "translate")
                                    } label: {
                                        Label("AI 翻译", systemImage: "character.bubble")
                                    }
                                    if item.contentType == "podcast" || item.contentType == "video" || item.isMedia {
                                        Button {
                                            runPipelineForItem(item: item, type: "transcribe")
                                        } label: {
                                            Label("AI 转录", systemImage: "waveform")
                                        }
                                    }
                                    if item.hasTranscript {
                                        Divider()
                                        Button {
                                            deleteTranscriptForItem(item: item)
                                        } label: {
                                            Label("删除转录稿", systemImage: "trash")
                                        }
                                    }
                                } label: {
                                    Label("内容处理", systemImage: "gearshape.2")
                                }
                                Button {
                                    runPipelineForItem(item: item, type: "fulltext")
                                } label: {
                                    Label("重新提取全文", systemImage: "arrow.triangle.2.circlepath")
                                }
                            }

                            if canManageExports {
                                Button {
                                    Task { _ = try? await export.forceExport(contentID: item.id) }
                                } label: {
                                    Label("触发导出规则", systemImage: "square.and.arrow.up.on.square")
                                }
                            }

                        }
                        // 最后一行出现时自动加载下一页（滚动到底分页，打破 300 条上限）
                        .onAppear {
                            if item.id == model.items.last?.id { model.loadMore() }
                        }
                }
                if model.hasMore {
                    HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                        .onAppear { model.loadMore() }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }


    /// 重新处理：与 Worker 共用 contentId 锁，并按包含关系合并 LLM 调用。
    private func reprocessItem(item: ContentSummary) {
        ProcessingCommandCoordinator.start(
            gateway: processing,
            contentID: item.id,
            title: item.title,
            operation: .allEnabled)
    }

    private func runPipelineForItem(item: ContentSummary, type: String) {
        guard let operation = ProcessingOperation(rawValue: type) else {
            model.showToast("不支持的处理类型")
            return
        }
        ProcessingCommandCoordinator.start(
            gateway: processing,
            contentID: item.id,
            title: item.title,
            operation: operation)
    }

    private func deleteTranscriptForItem(item: ContentSummary) {
        guard item.hasTranscript else { return }
        ProcessingCommandCoordinator.start(
            gateway: processing,
            contentID: item.id,
            title: item.title,
            operation: .deleteTranscript,
            trackProgress: false
        ) { snapshot in
            model.showToast(snapshot.message)
        }
    }

    private var canUpdateReadingState: Bool {
        permissions.allows(.updateReadingState, capability: .library)
    }

    private var canRunProcessing: Bool {
        permissions.allows(.runProcessing, capability: .processing)
    }

    private var canManageExports: Bool {
        permissions.allows(.manageExports, capability: .export)
    }
}

public extension View {
    func readBoardFieldBackground(focused: Bool = false) -> some View {
        padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                    .fill(ReadBoardDesign.C.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                    .strokeBorder(
                        focused
                            ? ReadBoardDesign.C.accent.opacity(0.4)
                            : ReadBoardDesign.C.hairline,
                        lineWidth: ReadBoardDesign.Line.hair)
            )
    }
}
#endif
