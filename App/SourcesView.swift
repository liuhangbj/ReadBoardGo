import ReadBoardContract
import ReadBoardGoCore
import SwiftUI

struct SourcesView: View {
    @Environment(ReadBoardGoSession.self) private var session
    @State private var snapshot: SourceCatalogSnapshot?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let snapshot {
                List(snapshot.sources) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.name).font(.headline)
                        Text("\(source.contentCount) 项 · \(source.enabled ? "已启用" : "已停用")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = source.error, !error.isEmpty {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                }
                .refreshable { await load() }
            } else if let errorMessage {
                ContentUnavailableView("无法加载订阅源", systemImage: "wifi.exclamationmark",
                                       description: Text(errorMessage))
            } else {
                ProgressView("正在加载订阅源…")
            }
        }
        .navigationTitle("订阅源")
        .task { await load() }
    }

    private func load() async {
        do { snapshot = try await session.sourceCatalog(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}
