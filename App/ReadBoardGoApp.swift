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
    }
}
