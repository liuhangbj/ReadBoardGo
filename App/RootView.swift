import ReadBoardGoCore
import SwiftUI

struct RootView: View {
  @Environment(ReadBoardGoSession.self) private var session

  var body: some View {
    Group {
      if session.isRestoringConnection {
        VStack(spacing: 12) {
          ProgressView()
          Text("正在验证 ReadBoard 服务…")
            .font(.system(size: 12))
            .foregroundStyle(Color.goTextSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if session.isConnected {
        MainTabView()
      } else {
        ConnectionView()
      }
    }
    .background(Color.goBackground)
    .tint(Color.goAccent)
    .overlay(alignment: .top) {
      if session.isConnected, let message = session.remoteHealth.message {
        remoteHealthBanner(session.isOffline ? offlineMessage(fallback: message) : message)
          .padding(.top, 10)
          .padding(.horizontal, 16)
      }
    }
    #if os(macOS)
      .frame(minWidth: 900, minHeight: 620)
    #endif
    .task(id: session.connection?.deviceID) {
      if session.connection != nil && session.profile == nil {
        await session.refreshProfile()
      }
      await session.monitorConnection()
    }
  }

  private func offlineMessage(fallback: String) -> String {
    guard let cachedAt = session.cachedAt else {
      return "已断开连接，正在使用本机最后保存的内容"
    }
    return "离线只读 · 数据更新于 \(cachedAt.formatted(date: .abbreviated, time: .shortened))"
  }

  private func remoteHealthBanner(_ message: String) -> some View {
    HStack(spacing: 8) {
      Image(systemName: session.remoteHealth.phase == .disconnected
        ? "network.slash" : "exclamationmark.triangle.fill")
      Text(message)
        .lineLimit(2)
      Spacer()
      Button("重新检查") {
        Task { await session.refreshProfile() }
      }
      .buttonStyle(.plain)
      .foregroundStyle(Color.goAccent)
    }
    .font(.system(size: 11))
    .foregroundStyle(Color.goTextSecondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 9))
    .overlay(
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(Color.goError.opacity(0.28), lineWidth: 0.5))
  }
}
