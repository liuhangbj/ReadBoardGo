#if os(macOS)
import ReadBoardContract
import ReadBoardCoreSnapshot
import ReadBoardGoCore
import ReadBoardRemote
import SwiftUI

/// 迁移第一阶段的零差异基线：直接运行完整 Core 前端快照，唯一替换项是
/// ReadBoardServices 中的本地 gateway 被远程 gateway 取代。
struct CoreSnapshotRootView: View {
  @Environment(ReadBoardGoSession.self) private var session

  private var configuration: ReadBoardConfiguration {
    ReadBoardConfiguration(
      edition: .proBeta,
      applicationSupportDirectoryName: "ReadBoard Go")
  }

  var body: some View {
    if let services = try? GoRemoteServicesFactory.make(session: session) {
      ReadBoardCoreSnapshot.RootView(
        configuration: configuration,
        services: services)
        .environment(\.readBoardConfiguration, configuration)
    } else {
      ContentUnavailableView(
        "无法装配远程阅读器",
        systemImage: "network.slash",
        description: Text("请返回连接页重新连接 ReadBoard 服务。"))
    }
  }

}

@MainActor
enum GoRemoteServicesFactory {
  static func make(session: ReadBoardGoSession) throws -> ReadBoardServices {
    let client = try session.remoteClient()
    return ReadBoardServices(
      library: RemoteLibraryGateway(client: client),
      contentDetail: RemoteContentDetailGateway(client: client),
      mediaPlayback: RemoteMediaPlaybackGateway(client: client),
      processing: RemoteProcessingGateway(client: client),
      sourceManagement: RemoteSourceManagementGateway(client: client),
      sourceCatalog: RemoteSourceCatalogGateway(client: client),
      sourceOnboarding: RemoteSourceOnboardingGateway(client: client),
      runtimeStatus: RemoteRuntimeStatusGateway(client: client),
      export: RemoteExportGateway(client: client),
      administration: RemoteAdministrationGateway(client: client),
      configuration: RemoteConfigurationGateway(client: client),
      authentication: RemoteAuthenticationGateway(client: client),
      maintenance: RemoteMaintenanceGateway(client: client),
      dependencyManagement: RemoteDependencyManagementGateway(client: client),
      remoteAccess: nil,
      remoteCapabilities: session.profile?.capabilities ?? [],
      remoteScopes: session.profile?.grantedScopes ?? session.connection?.scopes ?? [])
  }
}
#endif
