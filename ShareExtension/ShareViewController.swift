import AppKit
import UniformTypeIdentifiers

@objc(ReadBoardGoShareViewController)
final class ShareViewController: NSViewController {
  private let status = NSTextField(labelWithString: "正在添加到 ReadBoard Go…")

  override func loadView() {
    let root = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 92))
    status.alignment = .center
    status.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(status)
    NSLayoutConstraint.activate([
      status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      status.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      status.centerYAnchor.constraint(equalTo: root.centerYAnchor)
    ])
    view = root
  }

  override func viewDidAppear() {
    super.viewDidAppear()
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
      status.stringValue = "没有找到可用链接"; complete(after: 0.8); return
    }
    var value = URLComponents()
    value.scheme = "readboard-go"
    value.host = "inbox"
    value.queryItems = [URLQueryItem(name: "url", value: shared.absoluteString),
                        URLQueryItem(name: "request_id", value: UUID().uuidString)]
    guard let callback = value.url else { complete(after: 0); return }
    extensionContext?.open(callback) { [weak self] opened in
      DispatchQueue.main.async {
        self?.status.stringValue = opened ? "已发送到 ReadBoard Go" : "无法打开 ReadBoard Go"
        self?.complete(after: opened ? 0.2 : 1)
      }
    }
  }

  private func complete(after seconds: TimeInterval) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
      self?.extensionContext?.completeRequest(returningItems: nil)
    }
  }

  private static func firstURL(_ text: String) -> URL? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
    return detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
      .compactMap(\.url).first { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
  }
}
