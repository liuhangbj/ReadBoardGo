import ReadBoardContract
import ReadBoardGoCore
import SwiftUI

struct GoSettingsView: View {
    @Environment(ReadBoardGoSession.self) private var session

    var body: some View {
        Form {
            Section("服务器") {
                LabeledContent("名称", value: session.profile?.serverName ?? "ReadBoard")
                if let url = session.connection?.baseURL.absoluteString {
                    LabeledContent("地址", value: url)
                }
                LabeledContent("API", value: session.profile?.apiVersion ?? "—")
                LabeledContent("传输安全",
                    value: session.profile?.transportSecurity == "none" ? "局域网 HTTP" : "TLS")
            }

            Section("设备权限") {
                ForEach(session.profile?.grantedScopes ?? session.connection?.scopes ?? [],
                        id: \.self) { scope in
                    Label(scope.rawValue, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            if let error = session.errorMessage {
                Section { Text(error).foregroundStyle(.red) }
            }

            Section {
                Button("刷新服务信息") { Task { await session.refreshProfile() } }
                Button("断开连接", role: .destructive) { session.disconnect() }
            }
        }
        .navigationTitle("设置")
    }
}
