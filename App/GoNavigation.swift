import Foundation
import ReadBoardFeatures
import ReadBoardUI

typealias ReaderCollection = ReadBoardLibraryCollection

enum GoDestination: Hashable {
  case library(ReadBoardLibraryLocation)
  case sources
  case operations
  case settings

  var title: String {
    switch self {
    case .library(let location): location.title
    case .sources: "订阅源"
    case .operations: "运行状态"
    case .settings: "连接设置"
    }
  }
}
