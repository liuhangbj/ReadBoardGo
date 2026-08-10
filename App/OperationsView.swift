import ReadBoardFeatures
import ReadBoardGoCore
import ReadBoardUI
import SwiftUI

/// Go 只装配远程 gateway；运行状态与失败处理使用共享功能板块。
struct OperationsView: View {
  @Environment(ReadBoardGoSession.self) private var session

  var body: some View {
    if let environment = try? session.featureEnvironment() {
      ReadBoardOperationsFeatureView(environment: environment)
    } else {
      ReadBoardLibraryEmptyState(
        title: "尚未连接服务端",
        message: "请先完成 ReadBoard 服务连接。",
        icon: "network.slash")
    }
  }
}
