import ReadBoardContract
import ReadBoardFeatures
import ReadBoardGoCore
import ReadBoardUI
import SwiftUI

private enum MobileTab: Hashable {
  case library
  case sources
  case operations
  case settings
}

struct MainTabView: View {
  @Environment(ReadBoardGoSession.self) private var session

  var body: some View {
    #if os(macOS)
      DesktopMainView()
    #else
      MobileMainView()
    #endif
  }
}

#if os(macOS)
  private struct DesktopMainView: View {
    var body: some View {
      CoreSnapshotRootView()
    }
  }
#endif

#if os(iOS)
  private struct MobileMainView: View {
    @Environment(ReadBoardGoSession.self) private var session
    @State private var selectedTab: MobileTab = .library

    var body: some View {
      TabView(selection: $selectedTab) {
        NavigationStack { LibraryView() }
          .tabItem { Label("阅读", systemImage: "books.vertical") }
          .tag(MobileTab.library)

        if session.hasScope(.manageSources), session.hasCapability(.sourceManagement) {
          NavigationStack { SourcesView() }
            .tabItem { Label("订阅源", systemImage: "dot.radiowaves.left.and.right") }
            .tag(MobileTab.sources)
        }

        if session.hasScope(.manageOperations), session.hasCapability(.administration) {
          NavigationStack { OperationsView() }
            .tabItem { Label("运行", systemImage: "gauge.with.dots.needle.67percent") }
            .tag(MobileTab.operations)
        }

        NavigationStack { GoSettingsView() }
          .tabItem { Label("设置", systemImage: "network") }
          .tag(MobileTab.settings)
      }
      .tint(Color.goAccent)
    }
  }
#endif
