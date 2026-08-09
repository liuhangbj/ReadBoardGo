#if os(macOS)
import AVFoundation
import AVKit
import AppKit
import Combine
import Foundation
import ReadBoardContract
import SwiftUI
import WebKit

public enum ReadBoardVideoPlayerPlatform: Equatable {
    case youtube
    case bilibili

    public static func resolve(source: String) -> ReadBoardVideoPlayerPlatform {
        source.lowercased() == "bilibili" ? .bilibili : .youtube
    }
}

private enum ReadBoardVideoStreamMetadata {
    nonisolated static func normalizedDuration(_ seconds: Double) -> Double {
        seconds.isFinite && seconds > 0 ? seconds : 0
    }

    nonisolated static func durationHint(from url: URL) -> Double {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawValue = components.queryItems?.first(where: { $0.name == "dur" })?.value,
              let seconds = Double(rawValue) else { return 0 }
        return normalizedDuration(seconds)
    }
}

/// Core 复制基线中的 YouTube 播放器。播放器 UI 保持不变，直链解析通过媒体端口注入。
public struct ReadBoardYouTubePlayerView: View {
    public let videoID: String
    public let title: String
    private let mediaPlayback: any MediaPlaybackGateway

    @State private var player: AVPlayer?
    @State private var loadTask: Task<Void, Never>?
    @State private var resolvedStreamURL: URL?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var isPlaying = false
    @State private var hasStartedPlayback = false
    @State private var playWhenReady = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    private let playbackTimer = Timer.publish(
        every: 0.5,
        on: .main,
        in: .common).autoconnect()

    public init(
        videoID: String,
        title: String,
        mediaPlayback: any MediaPlaybackGateway
    ) {
        self.videoID = videoID
        self.title = title
        self.mediaPlayback = mediaPlayback
    }

    public var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg)
                    .fill(Color.black)
                if hasStartedPlayback, let player {
                    ReadBoardAVPlayerView(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
                } else {
                    ReadBoardYouTubeThumbnailView(videoID: videoID)
                        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
                }

                if let error = loadError, player == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.yellow.opacity(0.7))
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        Button("重试") { requestPlay() }
                            .font(.system(size: 12))
                            .foregroundStyle(ReadBoardDesign.C.accent)
                    }
                    .padding(16)
                    .background(
                        .black.opacity(0.72),
                        in: RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))
                } else if !hasStartedPlayback {
                    Button { requestPlay() } label: {
                        VStack(spacing: 10) {
                            if isLoading {
                                ProgressView()
                                    .controlSize(.large)
                                    .tint(.white)
                            } else {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 48))
                                    .foregroundStyle(Color.white.opacity(0.94))
                            }
                            Text(isLoading ? "正在预加载…" : (player == nil ? "准备播放" : "已就绪"))
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.82))
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(
                            .black.opacity(0.34),
                            in: RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.md))
                    }
                    .buttonStyle(.plain)
                }

                if !hasStartedPlayback, duration > 0 {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Text(formatTime(duration))
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(
                                    .black.opacity(0.72),
                                    in: RoundedRectangle(cornerRadius: 5))
                        }
                    }
                    .padding(10)
                    .allowsHitTesting(false)
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity)

            HStack(spacing: 12) {
                if player != nil {
                    Button { togglePlay() } label: {
                        Image(systemName: isPlaying
                            ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(ReadBoardDesign.C.accent)
                    }
                    .buttonStyle(.plain)
                }

                if player != nil || duration > 0 {
                    VStack(spacing: 4) {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(ReadBoardDesign.C.bg)
                                    .frame(height: 4)
                                Capsule()
                                    .fill(ReadBoardDesign.C.accent)
                                    .frame(
                                        width: duration > 0
                                            ? geometry.size.width * CGFloat(currentTime / duration)
                                            : 0,
                                        height: 4)
                            }
                        }
                        .frame(height: 4)
                        HStack {
                            Text(formatTime(currentTime))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ReadBoardDesign.C.text3)
                            Spacer()
                            Text(formatTime(duration))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(ReadBoardDesign.C.text3)
                        }
                    }
                }

                Button {
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(videoID)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 20))
                        .foregroundStyle(ReadBoardDesign.C.text3)
                }
                .buttonStyle(.plain)
                .help("Open in browser")

                Spacer()
            }
        }
        .padding(12)
        .background(ReadBoardDesign.C.surface)
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
        .onReceive(playbackTimer) { _ in refreshPlaybackState() }
        .onAppear { schedulePreload() }
        .onDisappear { cleanup() }
    }

    private func schedulePreload() {
        loadTask?.cancel()
        loadTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                try Task.checkCancellation()
                let source = try await mediaPlayback.youtubeStream(videoID: videoID)
                try Task.checkCancellation()
                guard let url = URL(string: source.url) else {
                    throw URLError(.badURL)
                }
                resolvedStreamURL = url
                duration = ReadBoardVideoStreamMetadata.durationHint(from: url)
            } catch is CancellationError {
                // 快速切换文章时正常取消。
            } catch {
                // 预解析失败不抢占阅读界面；点击播放时再显示错误并允许重试。
            }
        }
    }

    private func requestPlay() {
        if let player {
            hasStartedPlayback = true
            player.play()
            isPlaying = true
            return
        }
        playWhenReady = true
        guard !isLoading else { return }
        loadTask?.cancel()
        loadTask = Task { await resolveStream(autoplay: true) }
    }

    @MainActor
    private func resolveStream(autoplay: Bool) async {
        guard player == nil, !isLoading else {
            if autoplay { playWhenReady = true }
            return
        }
        isLoading = true
        loadError = nil
        do {
            let url: URL
            if let resolvedStreamURL {
                url = resolvedStreamURL
            } else {
                let source = try await mediaPlayback.youtubeStream(videoID: videoID)
                guard let resolved = URL(string: source.url) else {
                    throw URLError(.badURL)
                }
                url = resolved
            }
            try Task.checkCancellation()
            let item = AVPlayerItem(url: url)
            item.preferredForwardBufferDuration = 5
            let preparedPlayer = AVPlayer(playerItem: item)
            preparedPlayer.automaticallyWaitsToMinimizeStalling = true
            player = preparedPlayer
            isLoading = false
            if autoplay || playWhenReady {
                hasStartedPlayback = true
                preparedPlayer.play()
                isPlaying = true
                playWhenReady = false
            }
        } catch is CancellationError {
            isLoading = false
        } catch {
            isLoading = false
            loadError = error.localizedDescription
        }
    }

    private func refreshPlaybackState() {
        guard let player else { return }
        currentTime = player.currentTime().seconds
        if let item = player.currentItem {
            duration = ReadBoardVideoStreamMetadata.normalizedDuration(item.duration.seconds)
        }
        isPlaying = player.rate > 0
    }

    private func togglePlay() {
        guard let player else { return }
        hasStartedPlayback = true
        if isPlaying { player.pause() } else { player.play() }
        isPlaying = player.rate > 0
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let remainder = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%d:%02d", minutes, remainder)
    }

    private func cleanup() {
        loadTask?.cancel()
        loadTask = nil
        player?.currentItem?.cancelPendingSeeks()
        player?.pause()
        player = nil
        resolvedStreamURL = nil
        isLoading = false
        isPlaying = false
        hasStartedPlayback = false
        playWhenReady = false
    }
}

private struct ReadBoardYouTubeThumbnailView: View {
    let videoID: String

    var body: some View {
        AsyncImage(url: thumbnailURL(named: "maxresdefault")) { phase in
            switch phase {
            case .success(let image):
                fitted(image)
            case .failure:
                AsyncImage(url: thumbnailURL(named: "hqdefault")) { fallback in
                    if let image = fallback.image { fitted(image) } else { Color.black }
                }
            default:
                Color.black
            }
        }
        .background(Color.black)
    }

    private func thumbnailURL(named name: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoID)/\(name).jpg")
    }

    private func fitted(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

/// Core 复制基线中的 B站官方内嵌播放器。
public struct ReadBoardBilibiliPlayerView: View {
    public let bvid: String
    public let title: String
    public let pageURL: String

    public init(bvid: String, title: String, pageURL: String) {
        self.bvid = bvid
        self.title = title
        self.pageURL = pageURL
    }

    public var body: some View {
        VStack(spacing: 8) {
            ReadBoardBilibiliWebPlayer(bvid: bvid)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))

            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(ReadBoardDesign.C.text3)
                    .lineLimit(1)
                Spacer()
                Button {
                    let target = pageURL.isEmpty
                        ? "https://www.bilibili.com/video/\(bvid)"
                        : pageURL
                    if let url = URL(string: target) { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 20))
                        .foregroundStyle(ReadBoardDesign.C.text3)
                }
                .buttonStyle(.plain)
                .help("在浏览器中打开")
            }
        }
        .padding(12)
        .background(ReadBoardDesign.C.surface)
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
    }
}

private struct ReadBoardBilibiliWebPlayer: NSViewRepresentable {
    let bvid: String

    final class Coordinator {
        var loadedBVID: String?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        load(bvid: bvid, in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedBVID != bvid else { return }
        load(bvid: bvid, in: webView, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        coordinator.loadedBVID = nil
    }

    private func load(bvid: String, in webView: WKWebView, coordinator: Coordinator) {
        guard var components = URLComponents(
            string: "https://player.bilibili.com/player.html") else { return }
        components.queryItems = [
            URLQueryItem(name: "bvid", value: bvid),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "high_quality", value: "1"),
            URLQueryItem(name: "danmaku", value: "0"),
            URLQueryItem(name: "autoplay", value: "0")
        ]
        guard let url = components.url else { return }
        coordinator.loadedBVID = bvid
        var request = URLRequest(url: url, timeoutInterval: 45)
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        webView.load(request)
    }
}

private struct ReadBoardAVPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
#endif
