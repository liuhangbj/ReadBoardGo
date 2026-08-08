import Foundation
import ReadBoardContract
import ReadBoardGoCore
import SwiftUI

struct ArticleDetailView: View {
  @Environment(ReadBoardGoSession.self) private var session
  let summary: ContentSummary
  let onStateChange: (Bool, Bool) -> Void
  @State private var detail: ContentDetail?
  @State private var detailErrorMessage: String?
  @State private var operationErrorMessage: String?
  @State private var selectedMode = ArticleContentMode.original
  @State private var isRead: Bool
  @State private var isStarred: Bool
  @State private var isUpdatingState = false

  init(summary: ContentSummary, onStateChange: @escaping (Bool, Bool) -> Void) {
    self.summary = summary
    self.onStateChange = onStateChange
    _isRead = State(initialValue: summary.isRead)
    _isStarred = State(initialValue: summary.isStarred)
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        articleHeader
        Divider()
        detailContent
      }
      .frame(maxWidth: 760, alignment: .leading)
      .padding(.horizontal, 22)
      .padding(.vertical, 18)
    }
    .navigationTitle(summary.sourceName ?? summary.source)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar { articleToolbar }
    .task { await loadDetail() }
    .alert("操作失败", isPresented: operationErrorPresented) {
      Button("好", role: .cancel) {}
    } message: {
      Text(operationErrorMessage ?? "请稍后重试")
    }
  }

  private var articleHeader: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(detail?.translatedTitle ?? summary.translatedTitle ?? summary.title)
        .font(.largeTitle.bold())
        .textSelection(.enabled)

      HStack(spacing: 6) {
        Text(summary.sourceName ?? summary.source)
        if let author = summary.author, !author.isEmpty { Text("· \(author)") }
        if let publishedAt = summary.publishedAt {
          Text("·")
          Text(
            Date(timeIntervalSince1970: TimeInterval(publishedAt)),
            format: .dateTime.year().month().day())
        }
      }
      .font(.subheadline)
      .foregroundStyle(.secondary)

      if let score = detail?.score ?? summary.score {
        Label("\(score) 分", systemImage: "sparkles")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.tint)
      }

      if let summaryText = detail?.summary ?? summary.summary, !summaryText.isEmpty {
        Text(summaryText)
          .font(.headline)
          .padding(14)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
      }

      if availableModes.count > 1 {
        Picker("内容版本", selection: $selectedMode) {
          ForEach(availableModes) { mode in Text(mode.title).tag(mode) }
        }
        .pickerStyle(.segmented)
      }
    }
  }

  @ViewBuilder
  private var detailContent: some View {
    if let detail {
      let content = content(for: selectedMode, detail: detail)
      if content.isEmpty {
        ContentUnavailableView("暂无正文", systemImage: "doc.text")
          .frame(maxWidth: .infinity)
      } else {
        Text(renderedMarkdown(content))
          .font(.body)
          .lineSpacing(6)
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    } else if let detailErrorMessage {
      ContentUnavailableView {
        Label("正文加载失败", systemImage: "doc.text.magnifyingglass")
      } description: {
        Text(detailErrorMessage)
      } actions: {
        Button("重试") { Task { await loadDetail() } }
      }
      .frame(maxWidth: .infinity)
    } else {
      VStack(alignment: .leading, spacing: 10) {
        ForEach(0..<8, id: \.self) { _ in
          Text("正在加载正文内容，这是一段占位文字。")
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .redacted(reason: .placeholder)
    }
  }

  @ToolbarContentBuilder
  private var articleToolbar: some ToolbarContent {
    ToolbarItemGroup {
      if let url = originalURL {
        Link(destination: url) {
          Label("打开原文", systemImage: "safari")
        }
      }

      Button {
        Task { await updateReadState(!isRead) }
      } label: {
        Label(
          isRead ? "标为未读" : "标为已读",
          systemImage: isRead ? "envelope.badge" : "envelope.open")
      }
      .disabled(isUpdatingState || !session.hasScope(.updateReadingState))

      Button {
        Task { await updateStarredState(!isStarred) }
      } label: {
        Label(
          isStarred ? "取消收藏" : "收藏",
          systemImage: isStarred ? "star.fill" : "star")
      }
      .disabled(isUpdatingState || !session.hasScope(.updateReadingState))
    }
  }

  private var availableModes: [ArticleContentMode] {
    guard let detail else { return [.original] }
    var modes: [ArticleContentMode] = []
    if detail.contentMarkdown?.isEmpty == false { modes.append(.original) }
    if detail.translatedMarkdown?.isEmpty == false { modes.append(.translated) }
    if detail.transcriptMarkdown?.isEmpty == false { modes.append(.transcript) }
    return modes.isEmpty ? [.original] : modes
  }

  private var originalURL: URL? {
    guard let url = URL(string: summary.url),
      url.scheme == "https" || url.scheme == "http"
    else { return nil }
    return url
  }

  private var operationErrorPresented: Binding<Bool> {
    Binding(
      get: { operationErrorMessage != nil },
      set: { if !$0 { operationErrorMessage = nil } }
    )
  }

  @MainActor
  private func loadDetail() async {
    detailErrorMessage = nil
    do {
      let value = try await session.contentDetail(id: summary.id)
      guard !Task.isCancelled else { return }
      detail = value
      if value.translatedMarkdown?.isEmpty == false {
        selectedMode = .translated
      } else if value.contentMarkdown?.isEmpty == false {
        selectedMode = .original
      } else if value.transcriptMarkdown?.isEmpty == false {
        selectedMode = .transcript
      }
    } catch is CancellationError {
      return
    } catch {
      detailErrorMessage = error.localizedDescription
    }
  }

  private func content(for mode: ArticleContentMode, detail: ContentDetail) -> String {
    switch mode {
    case .original: detail.contentMarkdown ?? ""
    case .translated: detail.translatedMarkdown ?? ""
    case .transcript: detail.transcriptMarkdown ?? ""
    }
  }

  private func renderedMarkdown(_ markdown: String) -> AttributedString {
    (try? AttributedString(
      markdown: markdown,
      options: .init(interpretedSyntax: .full)
    )) ?? AttributedString(markdown)
  }

  @MainActor
  private func updateReadState(_ value: Bool) async {
    isUpdatingState = true
    defer { isUpdatingState = false }
    do {
      let state = try await session.setRead(id: summary.id, value: value)
      isRead = state.isRead
      isStarred = state.isStarred
      onStateChange(isRead, isStarred)
    } catch {
      operationErrorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func updateStarredState(_ value: Bool) async {
    isUpdatingState = true
    defer { isUpdatingState = false }
    do {
      let state = try await session.setStarred(id: summary.id, value: value)
      isRead = state.isRead
      isStarred = state.isStarred
      onStateChange(isRead, isStarred)
    } catch {
      operationErrorMessage = error.localizedDescription
    }
  }
}

private enum ArticleContentMode: String, Identifiable {
  case original
  case translated
  case transcript

  var id: String { rawValue }
  var title: String {
    switch self {
    case .original: "原文"
    case .translated: "译文"
    case .transcript: "转录"
    }
  }
}
