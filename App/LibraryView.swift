import Foundation
import ReadBoardContract
import ReadBoardGoCore
import SwiftUI

struct LibraryView: View {
  @Environment(ReadBoardGoSession.self) private var session
  @State private var items: [ContentSummary] = []
  @State private var nextCursor: String?
  @State private var isInitialLoading = false
  @State private var isLoadingMore = false
  @State private var errorMessage: String?
  @State private var loadedIdentity: LibraryQueryIdentity?
  @State private var searchText = ""
  @State private var readFilter = LibraryReadFilter.all
  @State private var categoryFilter = LibraryCategoryFilter.all
  @State private var sortOption = LibrarySortOption.newest

  var body: some View {
    content
      .navigationTitle("阅读")
      .searchable(text: $searchText, prompt: "搜索标题、摘要和正文")
      .toolbar { libraryToolbar }
      .task(id: queryIdentity) {
        if !searchText.isEmpty {
          try? await Task.sleep(for: .milliseconds(300))
        }
        guard !Task.isCancelled else { return }
        await reload(for: queryIdentity)
      }
  }

  @ViewBuilder
  private var content: some View {
    if isInitialLoading && items.isEmpty {
      List(0..<5, id: \.self) { _ in LibraryRowPlaceholder() }
        .listStyle(.plain)
    } else if let errorMessage, items.isEmpty {
      ContentUnavailableView {
        Label("无法加载内容", systemImage: "wifi.exclamationmark")
      } description: {
        Text(errorMessage)
      } actions: {
        Button("重试") { Task { await reload(for: queryIdentity) } }
      }
    } else if items.isEmpty {
      ContentUnavailableView {
        Label(emptyTitle, systemImage: emptySystemImage)
      } description: {
        Text(emptyDescription)
      }
    } else {
      List {
        if let errorMessage {
          Section {
            Button {
              Task { await reload(for: queryIdentity) }
            } label: {
              Label(errorMessage, systemImage: "arrow.clockwise.circle")
                .foregroundStyle(.orange)
            }
          }
        }

        ForEach(items) { item in
          NavigationLink {
            ArticleDetailView(summary: item) { isRead, isStarred in
              applyState(to: item.id, isRead: isRead, isStarred: isStarred)
            }
          } label: {
            LibraryRow(item: item)
          }
        }

        if nextCursor != nil {
          HStack {
            Spacer()
            ProgressView(isLoadingMore ? "正在加载更多…" : "继续加载")
              .controlSize(.small)
            Spacer()
          }
          .listRowSeparator(.hidden)
          .task { await loadMore(for: queryIdentity) }
        }
      }
      .listStyle(.plain)
      .refreshable { await reload(for: queryIdentity) }
    }
  }

  @ToolbarContentBuilder
  private var libraryToolbar: some ToolbarContent {
    ToolbarItemGroup {
      Menu {
        Picker("阅读状态", selection: $readFilter) {
          ForEach(LibraryReadFilter.allCases) { option in
            Label(option.title, systemImage: option.systemImage).tag(option)
          }
        }
        Picker("内容类型", selection: $categoryFilter) {
          ForEach(LibraryCategoryFilter.allCases) { option in
            Label(option.title, systemImage: option.systemImage).tag(option)
          }
        }
        Picker("排序", selection: $sortOption) {
          ForEach(LibrarySortOption.allCases) { option in
            Text(option.title).tag(option)
          }
        }
      } label: {
        Label(
          "筛选",
          systemImage: hasActiveFilter
            ? "line.3.horizontal.decrease.circle.fill"
            : "line.3.horizontal.decrease.circle")
      }

      Button {
        Task { await reload(for: queryIdentity) }
      } label: {
        Label("刷新", systemImage: "arrow.clockwise")
      }
      .disabled(isInitialLoading)
    }
  }

  private var queryIdentity: LibraryQueryIdentity {
    LibraryQueryIdentity(
      search: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
      readFilter: readFilter.rawValue,
      categoryFilter: categoryFilter.rawValue,
      sort: sortOption.rawValue
    )
  }

  private var hasActiveFilter: Bool {
    readFilter != .all || categoryFilter != .all || sortOption != .newest
  }

  private var emptyTitle: String {
    searchText.isEmpty && !hasActiveFilter ? "暂无内容" : "没有匹配的内容"
  }

  private var emptyDescription: String {
    searchText.isEmpty && !hasActiveFilter
      ? "ReadBoard 抓取的新内容会显示在这里。"
      : "试试更换关键词或减少筛选条件。"
  }

  private var emptySystemImage: String {
    searchText.isEmpty && !hasActiveFilter ? "tray" : "magnifyingglass"
  }

  @MainActor
  private func reload(for identity: LibraryQueryIdentity) async {
    if loadedIdentity != identity {
      items = []
      nextCursor = nil
    }
    isInitialLoading = true
    errorMessage = nil
    defer {
      if identity == queryIdentity { isInitialLoading = false }
    }

    do {
      let page = try await session.libraryPage(query(cursor: nil))
      guard !Task.isCancelled, identity == queryIdentity else { return }
      items = page.items
      nextCursor = page.nextCursor
      loadedIdentity = identity
    } catch is CancellationError {
      return
    } catch {
      guard identity == queryIdentity else { return }
      errorMessage = error.localizedDescription
    }
  }

  @MainActor
  private func loadMore(for identity: LibraryQueryIdentity) async {
    guard !isInitialLoading, !isLoadingMore, let cursor = nextCursor,
      identity == queryIdentity
    else { return }
    isLoadingMore = true
    errorMessage = nil
    defer { isLoadingMore = false }

    do {
      let page = try await session.libraryPage(query(cursor: cursor))
      guard !Task.isCancelled, identity == queryIdentity else { return }
      let existingIDs = Set(items.map(\.id))
      items.append(contentsOf: page.items.filter { !existingIDs.contains($0.id) })
      nextCursor = page.nextCursor
    } catch is CancellationError {
      return
    } catch {
      guard identity == queryIdentity else { return }
      errorMessage = error.localizedDescription
    }
  }

  private func query(cursor: String?) -> ContentQuery {
    ContentQuery(
      filter: ContentFilter(
        category: categoryFilter.category,
        readState: readFilter.readState,
        keyword: queryIdentity.search.isEmpty ? nil : queryIdentity.search
      ),
      sort: sortOption.sort,
      pageSize: 50,
      cursor: cursor
    )
  }

  private func applyState(to id: Int64, isRead: Bool, isStarred: Bool) {
    if (readFilter == .unread && isRead) || (readFilter == .starred && !isStarred) {
      items.removeAll { $0.id == id }
      return
    }
    guard let index = items.firstIndex(where: { $0.id == id }) else { return }
    items[index] = items[index].replacingState(isRead: isRead, isStarred: isStarred)
  }
}

private enum LibraryReadFilter: String, CaseIterable, Identifiable {
  case all
  case unread
  case starred

  var id: String { rawValue }
  var readState: ContentReadState {
    switch self {
    case .all: .all
    case .unread: .unread
    case .starred: .starred
    }
  }
  var title: String {
    switch self {
    case .all: "全部"
    case .unread: "未读"
    case .starred: "收藏"
    }
  }
  var systemImage: String {
    switch self {
    case .all: "tray.full"
    case .unread: "envelope.badge"
    case .starred: "star"
    }
  }
}

private enum LibraryCategoryFilter: String, CaseIterable, Identifiable {
  case all
  case article
  case podcast
  case video

  var id: String { rawValue }
  var category: ContentCategory? {
    switch self {
    case .all: nil
    case .article: .article
    case .podcast: .podcast
    case .video: .video
    }
  }
  var title: String {
    switch self {
    case .all: "全部类型"
    case .article: "文章"
    case .podcast: "播客"
    case .video: "视频"
    }
  }
  var systemImage: String {
    switch self {
    case .all: "square.stack"
    case .article: "doc.text"
    case .podcast: "headphones"
    case .video: "play.rectangle"
    }
  }
}

private enum LibrarySortOption: String, CaseIterable, Identifiable {
  case newest
  case oldest
  case score

  var id: String { rawValue }
  var sort: ContentSort {
    switch self {
    case .newest: .newest
    case .oldest: .oldest
    case .score: .score
    }
  }
  var title: String {
    switch self {
    case .newest: "最新优先"
    case .oldest: "最早优先"
    case .score: "评分优先"
    }
  }
}

private struct LibraryQueryIdentity: Equatable {
  let search: String
  let readFilter: String
  let categoryFilter: String
  let sort: String
}
