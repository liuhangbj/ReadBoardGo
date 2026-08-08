import ReadBoardGoCore
import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ConnectionView: View {
    @Environment(ReadBoardGoSession.self) private var session
    @State private var serverAddress = ""
    @State private var pairingCode = ""
    @State private var deviceName = Self.defaultDeviceName

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "rectangle.connected.to.line.below")
                            .font(.system(size: 42))
                            .foregroundStyle(.tint)
                        Text("连接 ReadBoard")
                            .font(.title2.bold())
                        Text("在服务端的“远程访问”设置中生成配对码，然后在这里完成连接。")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section("服务器") {
                    TextField("例如 10.0.0.5:7331", text: $serverAddress)
                        .textContentType(.URL)
                    TextField("设备名称", text: $deviceName)
                }

                Section("一次性配对码") {
                    TextField("8 位配对码", text: $pairingCode)
                        .pairingCodeInputStyle()
                        .font(.body.monospaced())
                }

                if let message = session.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            await session.pair(serverAddress: serverAddress,
                                               code: pairingCode,
                                               deviceName: deviceName)
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if session.isWorking { ProgressView().controlSize(.small) }
                            Text(session.isWorking ? "正在连接…" : "连接")
                            Spacer()
                        }
                    }
                    .disabled(session.isWorking || serverAddress.isEmpty || pairingCode.isEmpty)
                }

                Section {
                    Text("当前版本用于可信局域网。请勿将 ReadBoard 的 HTTP 端口直接暴露到公网。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("ReadBoard Go")
        }
    }

    private static var defaultDeviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #elseif os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        "ReadBoard Go"
        #endif
    }
}

private extension View {
    @ViewBuilder
    func pairingCodeInputStyle() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }
}
