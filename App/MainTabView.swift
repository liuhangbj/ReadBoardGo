import ReadBoardContract
import ReadBoardGoCore
import SwiftUI

private enum AppTab: Hashable {
    case library, sources, operations, settings
}

struct MainTabView: View {
    @Environment(ReadBoardGoSession.self) private var session
    @State private var selectedTab: AppTab = .library

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { LibraryView() }
                .tabItem { Label("阅读", systemImage: "books.vertical") }
                .tag(AppTab.library)

            if session.hasScope(.manageSources), session.hasCapability(.sourceManagement) {
                NavigationStack { SourcesView() }
                    .tabItem { Label("订阅源", systemImage: "dot.radiowaves.left.and.right") }
                    .tag(AppTab.sources)
            }

            if session.hasScope(.manageOperations), session.hasCapability(.administration) {
                NavigationStack { OperationsView() }
                    .tabItem { Label("运行", systemImage: "gauge.with.dots.needle.67percent") }
                    .tag(AppTab.operations)
            }

            NavigationStack { GoSettingsView() }
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }
}
