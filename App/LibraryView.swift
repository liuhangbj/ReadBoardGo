import ReadBoardContract
import ReadBoardGoCore
import SwiftUI

struct LibraryView: View {
    @Environment(ReadBoardGoSession.self) private var session
    @State private var items: [ContentSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isLoading && items.isEmpty {
                ProgressView("正在加载内容…")
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView("无法加载内容", systemImage: "wifi.exclamationmark",
                                       description: Text(errorMessage))
            } else if items.isEmpty {
                ContentUnavailableView("暂无内容", systemImage: "tray")
            } else {
                List(items) { item in
                    NavigationLink {
                        ArticleDetailView(summary: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.translatedTitle ?? item.title)
                                .font(.headline)
                                .foregroundStyle(item.isRead ? .secondary : .primary)
                                .lineLimit(2)
                            HStack {
                                Text(item.sourceName ?? item.source)
                                if let score = item.score { Text("· \(score) 分") }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            if let summary = item.summary ?? item.excerpt, !summary.isEmpty {
                                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                .refreshable { await load() }
            }
        }
        .navigationTitle("阅读")
        .toolbar {
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
        }
        .task { if items.isEmpty { await load() } }
    }

    @MainActor
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await session.libraryPage(
                ContentQuery(sort: .newest, pageSize: 50)).items
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ArticleDetailView: View {
    @Environment(ReadBoardGoSession.self) private var session
    let summary: ContentSummary
    @State private var detail: ContentDetail?
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(summary.translatedTitle ?? summary.title).font(.title.bold())
                Text(summary.sourceName ?? summary.source).foregroundStyle(.secondary)
                Divider()
                if let detail {
                    if let summary = detail.summary, !summary.isEmpty {
                        Text(summary).font(.headline)
                        Divider()
                    }
                    Text(detail.translatedMarkdown ?? detail.contentMarkdown
                         ?? detail.transcriptMarkdown ?? "暂无正文")
                        .textSelection(.enabled)
                } else if let errorMessage {
                    ContentUnavailableView("正文加载失败", systemImage: "doc.text.magnifyingglass",
                                           description: Text(errorMessage))
                } else {
                    ProgressView("正在加载正文…")
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding()
        }
        .toolbar {
            if session.hasScope(.updateReadingState) {
                Button("标为已读") {
                    Task { _ = try? await session.setRead(id: summary.id, value: true) }
                }
            }
        }
        .task {
            do { detail = try await session.contentDetail(id: summary.id) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
