import ReadBoardContract
import ReadBoardFeatures
import ReadBoardGoCore
import SwiftUI

struct GoCombinedSettingsView: View {
  @Environment(ReadBoardGoSession.self) private var session
  @StateObject private var navigation = ReadBoardSettingsNavigationStore.shared

  var body: some View {
    if let environment = try? session.featureEnvironment() {
      ReadBoardSettingsShell(
        pages: availablePages(environment),
        primaryItem: ReadBoardSettingsModuleDescriptor(
          id: Self.connectionID,
          title: "连接",
          icon: "server.rack"),
        route: navigation.route
      ) { destination in
        content(destination, environment: environment)
      }
      .tint(Color.goAccent)
    } else {
      GoSettingsView()
    }
  }

  private static let connectionID = "readboard.go.connection"

  private func content(
    _ destination: ReadBoardSettingsDestination,
    environment: ReadBoardFeatureEnvironment
  ) -> AnyView {
    switch destination {
    case .module(let identifier):
      if identifier == Self.connectionID { return AnyView(GoSettingsView()) }
      return AnyView(ContentUnavailableView("模块不可用", systemImage: "exclamationmark.triangle"))
    case .page(let page):
      return switch page {
      case .general: AnyView(ReadBoardGeneralSettingsPane(
        sourceManagement: environment.sourceManagement,
        configuration: environment.configuration))
      case .remote: AnyView(ContentUnavailableView(
        "仅能在服务端设置远程访问", systemImage: "server.rack"))
      case .reader: AnyView(ReadBoardReaderSettingsPane())
      case .inbox: AnyView(ReadBoardInboxSettingsPane(inbox: environment.inbox))
      case .llm: AnyView(ReadBoardLLMSettingsPane(
        configuration: environment.configuration))
      case .deps: AnyView(ReadBoardDependencySettingsPane(
        configuration: environment.configuration,
        dependencyManagement: environment.dependencyManagement,
        allowsServerPathEditing: false))
      case .boards: AnyView(ReadBoardFeatureBoardSettingsPane(
        configuration: environment.configuration))
      case .sources: AnyView(ReadBoardPlatformSettingsPane(
        sourceCatalog: environment.sourceCatalog,
        authentication: environment.authentication,
        configuration: environment.configuration,
        permissions: environment.permissions))
      case .fetch: AnyView(ReadBoardFulltextSettingsPane(
        configuration: environment.configuration))
      case .content: AnyView(ReadBoardAIContentSettingsPane(
        configuration: environment.configuration))
      case .export: AnyView(ReadBoardExportPlatformSettingsPane(
        configuration: environment.configuration,
        allowsServerPathEditing: false))
      case .pipeline: AnyView(ReadBoardExportRulesSettingsPane(
        export: environment.export,
        sourceCatalog: environment.sourceCatalog,
        configuration: environment.configuration))
      case .cleanup: AnyView(ReadBoardMaintenanceSettingsPane(
        maintenance: environment.maintenance))
      }
    }
  }

  private func availablePages(_ environment: ReadBoardFeatureEnvironment) -> [ReadBoardSettingsPage] {
    ReadBoardSettingsPage.allCases.filter { page in
      switch page {
      case .reader:
        true
      case .inbox:
        environment.permissions.allows(.manageConfiguration, capability: .configuration)
      case .remote:
        false
      case .general:
        environment.permissions.allows(.manageConfiguration, capability: .configuration)
          && environment.permissions.allows(.manageSources, capability: .sourceManagement)
      case .llm, .deps, .boards, .fetch, .content, .export:
        environment.permissions.allows(.manageConfiguration, capability: .configuration)
      case .sources:
        environment.permissions.allows(.manageSources, capability: .sourceManagement)
          || environment.permissions.allows(.manageAuthentication, capability: .authentication)
      case .pipeline:
        environment.permissions.allows(.manageExports, capability: .export)
          && environment.permissions.allows(.manageConfiguration, capability: .configuration)
          && environment.permissions.allows(.manageSources, capability: .sourceManagement)
      case .cleanup:
        environment.permissions.allows(.manageMaintenance, capability: .maintenance)
          && environment.permissions.allows(.manageOperations, capability: .administration)
      }
    }
  }
}

struct GoSettingsView: View {
  @Environment(ReadBoardGoSession.self) private var session

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: GoDesign.Space.xl) {
        GoPageHeader(
          eyebrow: "ReadBoard Go",
          title: "连接设置",
          subtitle: "这台设备与 ReadBoard 服务的连接和权限"
        ) {
          Button {
            Task { await session.refreshProfile() }
          } label: {
            Label("刷新", systemImage: "arrow.clockwise")
          }
          .buttonStyle(GoSecondaryButtonStyle())
        }

        serverCard
        securityCard
        permissionsCard

        if let error = session.errorMessage {
          HStack(alignment: .top, spacing: GoDesign.Space.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(Color.goError)
            Text(error)
              .font(.system(size: 11))
              .foregroundStyle(Color.goTextSecondary)
            Spacer()
          }
          .padding(GoDesign.Space.md)
          .background(Color.goError.opacity(0.08))
          .clipShape(RoundedRectangle(cornerRadius: GoDesign.Radius.lg))
        }

        HStack {
          Spacer()
          Button(role: .destructive) {
            session.disconnect()
          } label: {
            Label("断开这台设备", systemImage: "rectangle.portrait.and.arrow.right")
          }
          .buttonStyle(GoSecondaryButtonStyle())
        }
      }
      .padding(GoDesign.Space.xl)
      .frame(maxWidth: 860, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .topLeading)
    }
    .background(Color.goBackground)
    .navigationTitle("连接设置")
  }

  private var serverCard: some View {
    VStack(alignment: .leading, spacing: GoDesign.Space.sm) {
      GoSectionLabel(text: "服务器")
      GoPanel {
        VStack(spacing: 0) {
          settingRow(
            icon: "server.rack", color: .goAccent,
            title: "名称", value: session.profile?.serverName ?? "ReadBoard")
          GoHairline().padding(.leading, 38)
          settingRow(
            icon: "network", color: .goTranslate,
            title: "地址", value: session.connection?.baseURL.absoluteString ?? "—")
          GoHairline().padding(.leading, 38)
          settingRow(
            icon: "point.3.connected.trianglepath.dotted", color: .goSummary,
            title: "API 版本", value: session.profile?.apiVersion ?? "—")
        }
      }
    }
  }

  private var securityCard: some View {
    VStack(alignment: .leading, spacing: GoDesign.Space.sm) {
      GoSectionLabel(text: "安全")
      GoPanel {
        VStack(alignment: .leading, spacing: GoDesign.Space.md) {
          HStack(spacing: GoDesign.Space.md) {
            ZStack {
              RoundedRectangle(cornerRadius: GoDesign.Radius.md)
                .fill(Color.goSuccess.opacity(0.10))
              Image(systemName: "lock.shield.fill")
                .foregroundStyle(Color.goSuccess)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
              Text("TLS 证书已固定")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.goText)
              Text("证书变化时连接会在发送凭据前停止")
                .font(.system(size: 10))
                .foregroundStyle(Color.goTextTertiary)
            }
            Spacer()
            GoBadge(text: "安全连接", color: .goSuccess)
          }

          if let fingerprint = session.connection?.certificateFingerprint {
            GoHairline()
            VStack(alignment: .leading, spacing: 4) {
              Text("证书指纹")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.goTextTertiary)
              Text(formattedFingerprint(fingerprint))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.goTextSecondary)
                .textSelection(.enabled)
            }
          }
        }
      }
    }
  }

  private var permissionsCard: some View {
    VStack(alignment: .leading, spacing: GoDesign.Space.sm) {
      GoSectionLabel(text: "设备权限")
      GoPanel {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 8)], spacing: 8) {
          ForEach(scopes, id: \.self) { scope in
            HStack(spacing: 8) {
              Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.goSuccess)
              Text(scopeTitle(scope))
                .font(.system(size: 11))
                .foregroundStyle(Color.goTextSecondary)
              Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.goSurface.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: GoDesign.Radius.md))
          }
        }
      }
    }
  }

  private var scopes: [RemoteAccessScope] {
    session.profile?.grantedScopes ?? session.connection?.scopes ?? []
  }

  private func settingRow(icon: String, color: Color, title: String, value: String) -> some View {
    HStack(spacing: GoDesign.Space.md) {
      Image(systemName: icon)
        .font(.system(size: 12))
        .foregroundStyle(color)
        .frame(width: 26, height: 26)
        .background(color.opacity(0.09))
        .clipShape(RoundedRectangle(cornerRadius: GoDesign.Radius.md))
      Text(title)
        .font(.system(size: 11))
        .foregroundStyle(Color.goTextTertiary)
      Spacer()
      Text(value)
        .font(.system(size: 11))
        .foregroundStyle(Color.goText)
        .lineLimit(1)
        .textSelection(.enabled)
    }
    .padding(.vertical, 9)
  }

  private func scopeTitle(_ scope: RemoteAccessScope) -> String {
    switch scope {
    case .readLibrary: "读取资料库"
    case .updateReadingState: "更新阅读状态"
    case .manageOperations: "查看运行状态"
    case .runProcessing: "启动内容处理"
    case .manageSources: "管理订阅源"
    case .manageAuthentication: "管理平台授权"
    case .manageExports: "管理导出"
    case .manageConfiguration: "管理配置"
    case .manageMaintenance: "维护与备份"
    }
  }

  private func formattedFingerprint(_ value: String) -> String {
    stride(from: 0, to: value.count, by: 2).map { offset in
      let start = value.index(value.startIndex, offsetBy: offset)
      let end = value.index(
        start, offsetBy: min(2, value.distance(from: start, to: value.endIndex)))
      return String(value[start..<end]).uppercased()
    }.joined(separator: ":")
  }
}
