import ReadBoardFeatures
import ReadBoardGoCore
import ReadBoardUI
import SwiftUI

/// Go 只负责把远程环境装配给共享资料库板块，不再拥有页面状态或列表实现。
struct LibraryView: View {
  @Environment(ReadBoardGoSession.self) private var session
  let location: ReadBoardLibraryLocation

  init(location: ReadBoardLibraryLocation = .collection(.all)) {
    self.location = location
  }

  var body: some View {
    if let environment = try? session.featureEnvironment() {
      ReadBoardLibraryFeatureView(
        environment: environment,
        location: location,
        automaticallyMarksRead: true)
    } else {
      ReadBoardLibraryEmptyState(
        title: "尚未连接服务端",
        message: "请先完成 ReadBoard 服务连接。",
        icon: "network.slash")
    }
  }
}
