import ReadBoardContract
import SwiftUI

/// Go 中展示的是服务端依赖状态。路径也写回服务端，绝不打开客户端文件选择器，
/// 从而避免把另一台 Mac 的本地路径误存进 ReadBoard 主机。
public struct RemoteDepsPane: View {
    private let configuration: any ConfigurationGateway
    private let dependencyManagement: (any DependencyManagementGateway)?
    @State private var dependencies: [DependencyStatus] = []
    @State private var tasks: [DependencyTaskSnapshot] = []
    @State private var editingPaths: [String: String] = [:]
    @State private var message: String?
    @State private var isLoading = true

    public init(
        configuration: any ConfigurationGateway,
        dependencyManagement: (any DependencyManagementGateway)? = nil
    ) {
        self.configuration = configuration
        self.dependencyManagement = dependencyManagement
    }

    public var body: some View {
        Form {
            Section {
                if dependencies.isEmpty {
                    HStack(spacing: 10) {
                        if isLoading { ProgressView().controlSize(.small) }
                        Image(systemName: isLoading ? "clock" : "exclamationmark.triangle")
                            .foregroundStyle(Color.rbScoreMid)
                        Text(isLoading ? "正在读取服务端依赖状态…" : "服务端没有返回依赖状态，请刷新重试。")
                            .font(.caption)
                            .foregroundStyle(Color.rbText2)
                    }
                    .padding(.vertical, 8)
                }
                ForEach(dependencies) { dependency in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 10) {
                            Image(systemName: dependency.installed
                                  ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(dependency.installed ? Color.rbScoreHigh : Color.rbScoreMid)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(dependency.displayName)
                                    .font(.system(size: 13, weight: .semibold))
                                Text(dependency.version ?? (dependency.installed ? "已安装" : "服务端未找到"))
                                    .font(.caption)
                                    .foregroundStyle(Color.rbText3)
                            }
                            Spacer()
                            Text(dependency.installed ? "通过" : "缺失")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(dependency.installed ? Color.rbScoreHigh : Color.rbScoreMid)
                        }
                        if let task = activeTask(for: dependency.id) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(task.message).font(.caption).foregroundStyle(Color.rbText2)
                                Spacer()
                                Button("取消") { Task { await cancel(task) } }.controlSize(.small)
                            }
                        } else if let latest = tasks.first(where: { $0.dependencyID == dependency.id }),
                                  latest.phase == .failed {
                            Text(latest.message).font(.caption).foregroundStyle(Color.rbScoreLow)
                        }
                        HStack(spacing: 8) {
                            TextField("服务端可执行文件或模型路径", text: pathBinding(for: dependency))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                            Button("保存") { save(dependency) }
                                .controlSize(.small)
                                .disabled((editingPaths[dependency.id] ?? "") == (dependency.path ?? ""))
                            if dependencyManagement != nil, supportsTask(dependency.id) {
                                Button(dependency.installed ? "更新" : "安装") {
                                    Task { await submit(dependency) }
                                }
                                .controlSize(.small)
                                .disabled(activeTask(for: dependency.id) != nil)
                            }
                        }
                        if dependency.customPathIsStale {
                            Text("已保存的服务端路径不可用，请修改或清空后重新检测。")
                                .font(.caption)
                                .foregroundStyle(Color.rbScoreLow)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("服务端依赖")
                    Spacer()
                    Button { Task { await reload() } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            } footer: {
                Text("依赖实际安装在 ReadBoard 服务端。Go 只查看检测结果并修改服务端路径，不会访问这台客户端的文件。")
            }

            if let message {
                Section { Text(message).font(.caption).foregroundStyle(Color.rbText2) }
            }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await reload()
                let hasActive = tasks.contains { $0.phase == .queued || $0.phase == .running }
                try? await Task.sleep(for: .seconds(hasActive ? 1 : 10))
            }
        }
    }

    private func pathBinding(for dependency: DependencyStatus) -> Binding<String> {
        Binding(
            get: { editingPaths[dependency.id] ?? dependency.path ?? "" },
            set: { editingPaths[dependency.id] = $0 })
    }

    private func save(_ dependency: DependencyStatus) {
        let path = (editingPaths[dependency.id] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            await configuration.setDependencyPath(id: dependency.id, path: path)
            message = "已保存 \(dependency.displayName) 的服务端路径"
            await reload()
        }
    }

    private func activeTask(for dependencyID: String) -> DependencyTaskSnapshot? {
        tasks.first { $0.dependencyID == dependencyID && ($0.phase == .queued || $0.phase == .running) }
    }

    private func supportsTask(_ dependencyID: String) -> Bool {
        ["node", "whisperCLI", "ffmpeg", "ytdlp", "whisperModel"].contains(dependencyID)
    }

    private func submit(_ dependency: DependencyStatus) async {
        guard let dependencyManagement else { return }
        do {
            _ = try await dependencyManagement.submit(DependencyTaskRequest(
                dependencyID: dependency.id,
                operation: dependency.installed ? .update : .install))
            await reload()
        } catch { message = error.localizedDescription }
    }

    private func cancel(_ task: DependencyTaskSnapshot) async {
        await dependencyManagement?.cancel(taskID: task.id)
        await reload()
    }

    @MainActor
    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        if let dependencyManagement {
            let snapshot = await dependencyManagement.snapshot()
            dependencies = snapshot.dependencies
            tasks = snapshot.tasks
        } else {
            dependencies = await configuration.snapshot().dependencies
            tasks = []
        }
        editingPaths = Dictionary(uniqueKeysWithValues: dependencies.map {
            ($0.id, $0.path ?? "")
        })
    }
}

/// 远程版导出设置使用服务端路径文本，避免客户端目录选择器产生跨机器无效路径。
public struct RemoteExportPlatformPane: View {
    private let configuration: any ConfigurationGateway
    @State private var value = ExportPlatformConfiguration()
    @State private var webhookHeaders = ""
    @State private var saveTask: Task<Void, Never>?

    public init(configuration: any ConfigurationGateway) {
        self.configuration = configuration
    }

    public var body: some View {
        Form {
            Section("Obsidian / Markdown 目录") {
                Toggle("启用 Obsidian 导出", isOn: $value.obsidianEnabled)
                    .tint(Color.rbAccent)
                    .onChange(of: value.obsidianEnabled) { _, _ in scheduleSave() }
                if value.obsidianEnabled {
                    TextField("服务端 Vault 绝对路径", text: $value.obsidianDirectory)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: value.obsidianDirectory) { _, _ in scheduleSave() }
                    Text("该目录位于 ReadBoard 服务端，不是当前 Go 客户端。")
                        .font(.caption)
                        .foregroundStyle(Color.rbText3)
                }
            }

            Section("Webhook") {
                Toggle("启用 Webhook", isOn: $value.webhookEnabled)
                    .tint(Color.rbAccent)
                    .onChange(of: value.webhookEnabled) { _, _ in scheduleSave() }
                if value.webhookEnabled {
                    TextField("https://…", text: $value.webhookURL)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: value.webhookURL) { _, _ in scheduleSave() }
                    Text("自定义 Header（每行 Key: Value）")
                        .font(.caption)
                        .foregroundStyle(Color.rbText3)
                    TextEditor(text: $webhookHeaders)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 72)
                        .overlay(RoundedRectangle(cornerRadius: RB.Radius.sm)
                            .stroke(Color.rbSeparator, lineWidth: 0.5))
                        .onChange(of: webhookHeaders) { _, _ in scheduleSave() }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            value = await configuration.snapshot().exportPlatforms
            webhookHeaders = value.webhookHeaders
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        }
        .onDisappear {
            saveTask?.cancel()
            persist()
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            persist()
        }
    }

    private func persist() {
        value.webhookHeaders = Dictionary(uniqueKeysWithValues: webhookHeaders
            .split(separator: "\n")
            .compactMap { line -> (String, String)? in
                let parts = line.split(separator: ":", maxSplits: 1)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 && !parts[0].isEmpty ? (parts[0], parts[1]) : nil
            })
        let payload = value
        Task { await configuration.updateExportPlatforms(payload) }
    }
}
