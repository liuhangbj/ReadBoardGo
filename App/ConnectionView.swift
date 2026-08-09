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
  @State private var showManualConnection = false
  @State private var showPairingFallback = false
  @FocusState private var focusedField: ConnectionField?

  var body: some View {
    ZStack {
      Color.goBackground.ignoresSafeArea()

      ScrollView {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .top, spacing: 0) {
            brandPanel
              .frame(minWidth: 270, idealWidth: 320, maxWidth: 360)
            GoHairline(vertical: true)
            connectionPanel
              .frame(minWidth: 440, maxWidth: 560)
              .frame(maxWidth: .infinity)
          }
          .frame(minHeight: 610)

          VStack(spacing: 0) {
            compactBrand
            connectionPanel
          }
        }
        .frame(maxWidth: 980)
        .frame(maxWidth: .infinity)
      }
    }
    .tint(Color.goAccent)
    .task { session.discovery.start() }
    .onDisappear {
      if !session.isConnected { session.discovery.stop() }
    }
  }

  private var brandPanel: some View {
    VStack(alignment: .leading, spacing: GoDesign.Space.xl) {
      brandMark
      Spacer()
      VStack(alignment: .leading, spacing: GoDesign.Space.md) {
        GoSectionLabel(text: "ReadBoard Go")
        Text("把你的信息中台，\n带到每一块屏幕。")
          .font(.system(size: 30, weight: .semibold, design: .serif))
          .foregroundStyle(Color.goText)
          .fixedSize(horizontal: false, vertical: true)
        Text("抓取、处理和数据库留在 ReadBoard；Go 只负责安全、安静地阅读。")
          .font(.system(size: 13))
          .foregroundStyle(Color.goTextSecondary)
          .lineSpacing(4)
      }
      Spacer()
      HStack(spacing: GoDesign.Space.sm) {
        Image(systemName: "lock.shield")
        Text("局域网发现 · TLS 固定 · 设备令牌")
      }
      .font(.system(size: 11))
      .foregroundStyle(Color.goTextTertiary)
    }
    .padding(GoDesign.Space.xxl)
    .background(Color.goSidebar)
  }

  private var compactBrand: some View {
    HStack(spacing: GoDesign.Space.md) {
      brandMark
      VStack(alignment: .leading, spacing: 2) {
        Text("ReadBoard Go")
          .font(.system(size: 18, weight: .semibold, design: .serif))
          .foregroundStyle(Color.goText)
        Text("连接你的 ReadBoard")
          .font(.system(size: 11))
          .foregroundStyle(Color.goTextTertiary)
      }
      Spacer()
    }
    .padding(.horizontal, GoDesign.Space.xl)
    .padding(.top, GoDesign.Space.xl)
  }

  private var brandMark: some View {
    ZStack {
      RoundedRectangle(cornerRadius: GoDesign.Radius.lg)
        .fill(Color.goAccent.opacity(0.12))
      RoundedRectangle(cornerRadius: GoDesign.Radius.lg)
        .strokeBorder(Color.goAccent.opacity(0.25), lineWidth: GoDesign.hairline)
      Text("R")
        .font(.system(size: 21, weight: .semibold, design: .serif))
        .foregroundStyle(Color.goAccent)
    }
    .frame(width: 42, height: 42)
  }

  private var connectionPanel: some View {
    VStack(alignment: .leading, spacing: GoDesign.Space.xl) {
      VStack(alignment: .leading, spacing: GoDesign.Space.xs) {
        GoSectionLabel(text: session.trustCandidate == nil ? "第一步" : "第二步")
        Text(session.trustCandidate == nil ? "选择 ReadBoard" : "确认并登录")
          .font(.system(size: 24, weight: .semibold, design: .serif))
          .foregroundStyle(Color.goText)
        Text(
          session.trustCandidate == nil
            ? "同一局域网中的服务会自动出现在这里。"
            : "首次登录后，这台设备将使用独立令牌无感连接。"
        )
        .font(.system(size: 12))
        .foregroundStyle(Color.goTextSecondary)
      }

      if let candidate = session.trustCandidate {
        loginContent(candidate)
      } else {
        discoveryContent
      }

      if let message = session.errorMessage {
        errorBanner(message)
      }

      securityNote
    }
    .padding(GoDesign.Space.xxl)
  }

  private var discoveryContent: some View {
    VStack(alignment: .leading, spacing: GoDesign.Space.md) {
      HStack {
        GoSectionLabel(text: "附近的服务")
        Spacer()
        if session.discovery.servers.isEmpty {
          ProgressView().controlSize(.small).tint(Color.goAccent)
        } else {
          Text("发现 \(session.discovery.servers.count) 台")
            .font(.system(size: 10).monospacedDigit())
            .foregroundStyle(Color.goTextTertiary)
        }
      }

      if session.discovery.servers.isEmpty {
        GoPanel {
          HStack(spacing: GoDesign.Space.md) {
            ZStack {
              Circle().fill(Color.goAccent.opacity(0.10))
              Image(systemName: "dot.radiowaves.left.and.right")
                .foregroundStyle(Color.goAccent)
            }
            .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
              Text("正在查找 ReadBoard")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.goText)
              Text(session.discovery.statusMessage)
                .font(.system(size: 11))
                .foregroundStyle(Color.goTextTertiary)
            }
            Spacer()
          }
        }
      } else {
        VStack(spacing: GoDesign.Space.xs) {
          ForEach(session.discovery.servers) { server in
            Button {
              session.select(server)
            } label: {
              HStack(spacing: GoDesign.Space.md) {
                ZStack {
                  RoundedRectangle(cornerRadius: GoDesign.Radius.md)
                    .fill(Color.goSuccess.opacity(0.10))
                  Image(systemName: "server.rack")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.goSuccess)
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                  Text(server.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.goText)
                    .lineLimit(1)
                  Text(server.baseURLs.first?.absoluteString ?? "HTTPS 服务")
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(Color.goTextTertiary)
                    .lineLimit(1)
                }
                Spacer()
                GoBadge(text: "在线", color: .goSuccess)
                Image(systemName: "chevron.right")
                  .font(.system(size: 10, weight: .semibold))
                  .foregroundStyle(Color.goTextTertiary)
              }
              .padding(GoDesign.Space.md)
              .background(Color.goSurface.opacity(0.55))
              .clipShape(RoundedRectangle(cornerRadius: GoDesign.Radius.lg))
              .overlay {
                RoundedRectangle(cornerRadius: GoDesign.Radius.lg)
                  .strokeBorder(Color.goHairline, lineWidth: GoDesign.hairline)
              }
            }
            .buttonStyle(.plain)
          }
        }
      }

      DisclosureGroup("找不到服务？手动输入地址", isExpanded: $showManualConnection) {
        VStack(alignment: .leading, spacing: GoDesign.Space.sm) {
          TextField("例如 10.0.0.5:7331", text: $serverAddress)
            .textFieldStyle(.plain)
            .textContentType(.URL)
            .focused($focusedField, equals: .server)
            .goField(focused: focusedField == .server)
          Button {
            Task { await session.inspectServer(address: serverAddress) }
          } label: {
            Label(
              session.isWorking ? "正在检查证书…" : "检查服务器",
              systemImage: "network.badge.shield.half.filled")
          }
          .buttonStyle(GoSecondaryButtonStyle())
          .disabled(session.isWorking || serverAddress.isEmpty)
        }
        .padding(.top, GoDesign.Space.sm)
      }
      .font(.system(size: 11))
      .foregroundStyle(Color.goTextSecondary)
    }
  }

  private func loginContent(_ candidate: ServerTrustCandidate) -> some View {
    VStack(alignment: .leading, spacing: GoDesign.Space.lg) {
      GoPanel {
        VStack(alignment: .leading, spacing: GoDesign.Space.md) {
          HStack(spacing: GoDesign.Space.md) {
            ZStack {
              RoundedRectangle(cornerRadius: GoDesign.Radius.md)
                .fill(Color.goAccent.opacity(0.10))
              Image(systemName: "server.rack")
                .foregroundStyle(Color.goAccent)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
              Text(candidate.name)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.goText)
              Text(candidate.baseURL.absoluteString)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(Color.goTextTertiary)
                .lineLimit(1)
            }
            Spacer()
            GoBadge(text: "TLS", color: .goSuccess)
          }
          GoHairline()
          VStack(alignment: .leading, spacing: 4) {
            Text("证书指纹")
              .font(.system(size: 10, weight: .medium))
              .foregroundStyle(Color.goTextTertiary)
            Text(formattedFingerprint(candidate.certificateFingerprint))
              .font(.system(size: 9, design: .monospaced))
              .foregroundStyle(Color.goTextSecondary)
              .textSelection(.enabled)
              .lineLimit(2)
          }
          Button("选择其他服务") { session.cancelTrustCandidate() }
            .buttonStyle(GoQuietButtonStyle())
        }
      }

      VStack(alignment: .leading, spacing: GoDesign.Space.sm) {
        GoSectionLabel(text: "设备")
        TextField("设备名称", text: $deviceName)
          .textFieldStyle(.plain)
          .focused($focusedField, equals: .device)
          .goField(focused: focusedField == .device)
      }

      VStack(alignment: .leading, spacing: GoDesign.Space.sm) {
        GoSectionLabel(text: "访问密码")
        SecureField("在 ReadBoard 中设置的远程访问密码", text: $password)
          .textFieldStyle(.plain)
          .focused($focusedField, equals: .password)
          .goField(focused: focusedField == .password)
          .onSubmit { login() }
      }

      Button(action: login) {
        HStack(spacing: GoDesign.Space.sm) {
          if session.isWorking { ProgressView().controlSize(.small).tint(Color.goOnAccent) }
          Text(session.isWorking ? "正在登录…" : "连接并开始阅读")
        }
      }
      .buttonStyle(GoPrimaryButtonStyle())
      .disabled(session.isWorking || password.isEmpty || deviceName.isEmpty)
      .opacity(session.isWorking || password.isEmpty || deviceName.isEmpty ? 0.48 : 1)

      DisclosureGroup("改用一次性配对码", isExpanded: $showPairingFallback) {
        VStack(alignment: .leading, spacing: GoDesign.Space.sm) {
          TextField("8 位配对码", text: $pairingCode)
            .textFieldStyle(.plain)
            .pairingCodeInputStyle()
            .font(.system(.body, design: .monospaced))
            .focused($focusedField, equals: .pairingCode)
            .goField(focused: focusedField == .pairingCode)
          Button("使用配对码连接") {
            Task { await session.pair(code: pairingCode, deviceName: deviceName) }
          }
          .buttonStyle(GoSecondaryButtonStyle())
          .disabled(session.isWorking || pairingCode.isEmpty)
        }
        .padding(.top, GoDesign.Space.sm)
      }
      .font(.system(size: 11))
      .foregroundStyle(Color.goTextSecondary)
    }
  }

  private var securityNote: some View {
    HStack(alignment: .top, spacing: GoDesign.Space.sm) {
      Image(systemName: "lock.shield")
        .font(.system(size: 11))
        .foregroundStyle(Color.goSuccess)
      Text("首次连接会固定服务器证书。证书变化时，Go 会在发送密码或设备令牌前停止连接。")
        .font(.system(size: 10))
        .foregroundStyle(Color.goTextTertiary)
        .lineSpacing(3)
    }
  }

  private func errorBanner(_ message: String) -> some View {
    HStack(alignment: .top, spacing: GoDesign.Space.sm) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(Color.goError)
      Text(message)
        .font(.system(size: 11))
        .foregroundStyle(Color.goTextSecondary)
      Spacer()
    }
    .padding(GoDesign.Space.md)
    .background(Color.goError.opacity(0.08))
    .clipShape(RoundedRectangle(cornerRadius: GoDesign.Radius.lg))
    .overlay {
      RoundedRectangle(cornerRadius: GoDesign.Radius.lg)
        .strokeBorder(Color.goError.opacity(0.22), lineWidth: GoDesign.hairline)
    }
  }

  private func login() {
    guard !password.isEmpty, !deviceName.isEmpty, !session.isWorking else { return }
    Task { await session.login(password: password, deviceName: deviceName) }
  }

  private func formattedFingerprint(_ value: String) -> String {
    stride(from: 0, to: value.count, by: 2).map { offset in
      let start = value.index(value.startIndex, offsetBy: offset)
      let end = value.index(
        start, offsetBy: min(2, value.distance(from: start, to: value.endIndex)))
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

private enum ConnectionField: Hashable {
  case server
  case device
  case password
  case pairingCode
}

extension View {
  @ViewBuilder
  fileprivate func pairingCodeInputStyle() -> some View {
    #if os(iOS)
      textInputAutocapitalization(.characters)
        .autocorrectionDisabled()
    #else
      self
    #endif
  }
}
