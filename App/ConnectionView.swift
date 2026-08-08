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
    @State private var password = ""
    @State private var pairingCode = ""
    @State private var deviceName = Self.defaultDeviceName
    @State private var showPairingFallback = false

    var body: some View {
        NavigationStack {
            Form {
                header

                if let candidate = session.trustCandidate {
                    trustedServer(candidate)
                } else {
                    discoveredServers
                    manualServer
                }

                if let message = session.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Text("首次连接会固定服务器 TLS 证书；证书发生变化时，ReadBoard Go 会拒绝发送密码和设备令牌。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("ReadBoard Go")
        }
        .task { session.discovery.start() }
        .onDisappear { if !session.isConnected { session.discovery.stop() } }
    }

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: 42)).foregroundStyle(.tint)
                Text("连接 ReadBoard").font(.title2.bold())
                Text("选择局域网中发现的服务器，首次输入访问密码后即可长期无感连接。")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var discoveredServers: some View {
        Section("附近的 ReadBoard") {
            if session.discovery.servers.isEmpty {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(session.discovery.statusMessage).foregroundStyle(.secondary)
                }
            } else {
                ForEach(session.discovery.servers) { server in
                    Button { session.select(server) } label: {
                        HStack {
                            Label(server.name, systemImage: "server.rack")
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var manualServer: some View {
        Section("手动连接") {
            TextField("例如 10.0.0.5:7331", text: $serverAddress)
                .textContentType(.URL)
            Button(session.isWorking ? "正在检查证书…" : "检查服务器") {
                Task { await session.inspectServer(address: serverAddress) }
            }
            .disabled(session.isWorking || serverAddress.isEmpty)
        }
    }

    private func trustedServer(_ candidate: ServerTrustCandidate) -> some View {
        Group {
            Section("服务器") {
                LabeledContent("名称", value: candidate.name)
                LabeledContent("地址", value: candidate.baseURL.absoluteString)
                VStack(alignment: .leading, spacing: 4) {
                    Text("TLS 证书指纹").font(.caption).foregroundStyle(.secondary)
                    Text(formattedFingerprint(candidate.certificateFingerprint))
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                }
                Button("选择其他服务器") { session.cancelTrustCandidate() }
                    .controlSize(.small)
            }

            Section("登录") {
                TextField("设备名称", text: $deviceName)
                SecureField("远程访问密码", text: $password)
                Button {
                    Task { await session.login(password: password, deviceName: deviceName) }
                } label: {
                    HStack {
                        Spacer()
                        if session.isWorking { ProgressView().controlSize(.small) }
                        Text(session.isWorking ? "正在登录…" : "登录")
                        Spacer()
                    }
                }
                .disabled(session.isWorking || password.isEmpty || deviceName.isEmpty)
            }

            Section {
                DisclosureGroup("使用一次性配对码", isExpanded: $showPairingFallback) {
                    TextField("8 位配对码", text: $pairingCode)
                        .pairingCodeInputStyle().font(.body.monospaced())
                    Button("使用配对码连接") {
                        Task { await session.pair(code: pairingCode, deviceName: deviceName) }
                    }
                    .disabled(session.isWorking || pairingCode.isEmpty)
                }
            }
        }
    }

    private func formattedFingerprint(_ value: String) -> String {
        stride(from: 0, to: value.count, by: 2).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: min(2, value.distance(from: start,
                                                                         to: value.endIndex)))
            return String(value[start..<end]).uppercased()
        }.joined(separator: ":")
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
