import UIKit
import UniformTypeIdentifiers

@objc(ReadBoardGoShareViewControllerIOS)
final class ShareViewControllerIOS: UIViewController {
  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    let providers = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem }
      .flatMap { $0.attachments ?? [] } ?? []
    if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }) {
      provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { [weak self] value, _ in
        let shared = value as? URL ?? (value as? String).flatMap(URL.init(string:))
        DispatchQueue.main.async { self?.send(shared) }
      }
    } else if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }) {
      provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] value, _ in
        let text = value as? String
        DispatchQueue.main.async { self?.send(text.flatMap(Self.firstURL)) }
      }
    } else {
      send(nil)
    }
  }

  private func send(_ shared: URL?) {
    guard let shared, ["http", "https"].contains(shared.scheme?.lowercased() ?? "") else {
      extensionContext?.cancelRequest(withError: URLError(.badURL)); return
    }
    var value = URLComponents()
    value.scheme = "readboard-go"
    value.host = "inbox"
    value.queryItems = [URLQueryItem(name: "url", value: shared.absoluteString),
                        URLQueryItem(name: "request_id", value: UUID().uuidString)]
    guard let callback = value.url else {
      extensionContext?.cancelRequest(withError: URLError(.badURL)); return
    }
    extensionContext?.open(callback) { [weak self] opened in
      DispatchQueue.main.async {
        if opened { self?.extensionContext?.completeRequest(returningItems: nil) }
        else { self?.extensionContext?.cancelRequest(withError: URLError(.cannotOpenFile)) }
      }
    }
  }

  private static func firstURL(_ text: String) -> URL? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
    return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
      .compactMap(\.url).first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
  }
}
