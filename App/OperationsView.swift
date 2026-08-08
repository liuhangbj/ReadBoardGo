import ReadBoardContract
import ReadBoardGoCore
import SwiftUI

struct OperationsView: View {
    @Environment(ReadBoardGoSession.self) private var session
    @State private var status = RuntimeStatusSnapshot()
    @State private var authentications: [PlatformAuthenticationStatus] = []

    var body: some View {
        List {
            Section("处理状态") {
                LabeledContent("阶段", value: status.phase.rawValue)
                LabeledContent("队列", value: "\(status.queue.items)")
                LabeledContent("暂停错误", value: "\(status.pausedFailureCount)")
                if !status.lastSummary.isEmpty { Text(status.lastSummary).foregroundStyle(.secondary) }
            }
            if session.hasScope(.manageAuthentication), !authentications.isEmpty {
                Section("平台授权") {
                    ForEach(authentications) { item in
                        LabeledContent(item.displayName, value: item.phase.rawValue)
                    }
                }
            }
        }
        .navigationTitle("运行状态")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        async let runtime = session.runtimeStatus()
        async let auth = session.authenticationStatuses()
        status = await runtime
        authentications = await auth
    }
}
