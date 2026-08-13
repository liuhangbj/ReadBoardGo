import ReadBoardContract
import ReadBoardGoCore
import SwiftUI

@main
struct ReadBoardGoApp: App {
  @State private var session = ReadBoardGoSession()

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(session)
        .onOpenURL { callback in
          guard callback.host == "inbox" || callback.host == "add",
                let raw = URLComponents(url: callback, resolvingAgainstBaseURL: false)?
                  .queryItems?.first(where: { $0.name == "url" })?.value else { return }
          let components = URLComponents(url: callback, resolvingAgainstBaseURL: false)
          let requestID = components?.queryItems?.first(where: { $0.name == "request_id" })?.value
            ?? UUID().uuidString
          let kind = components?.queryItems?.first(where: { $0.name == "kind" })?.value
            .flatMap(InboxContentKind.init(rawValue:)) ?? .automatic
          session.enqueueInboxImport(
            InboxImportRequest(requestID: requestID, url: raw, suggestedKind: kind))
        }
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
