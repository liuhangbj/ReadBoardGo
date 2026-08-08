import ReadBoardGoCore
import SwiftUI

struct RootView: View {
    @Environment(ReadBoardGoSession.self) private var session

    var body: some View {
        Group {
            if session.isConnected {
                MainTabView()
            } else {
                ConnectionView()
            }
        }
        .task(id: session.connection?.deviceID) {
            if session.isConnected { await session.refreshProfile() }
        }
    }
}
