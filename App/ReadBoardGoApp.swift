import ReadBoardGoCore
import SwiftUI

@main
struct ReadBoardGoApp: App {
  @State private var session = ReadBoardGoSession()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(session)
    }
    #if os(macOS)
      .defaultSize(width: 1180, height: 760)
    #endif

    #if os(macOS)
      Settings {
        GoCombinedSettingsView()
          .environment(session)
          .frame(minWidth: 720, minHeight: 500)
      }
    #endif
  }
}
