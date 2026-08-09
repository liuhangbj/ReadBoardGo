import SwiftUI
import Combine
import AVFoundation
import AVKit
import WebKit
import ReadBoardSharedUI

// MARK: - 复用样式组件（纸墨系）
//
// Hairline / VHairline（替换全部 Divider）、SectionLabel（眉题小标题）、
// RBadge（去 bold、底 10% + 同色 hairline 描边）、QuietButtonStyle（hover 浮现）、
// RowHoverButtonStyle（列表/左栏行 hover）、PrimaryCapsuleButtonStyle（关键动作）、
// CapsuleButton（次级动作）、StatusBanner（状态横幅）、rbFieldBackground（输入框）。

// 迁移期兼容名：复制版调用不变，基础视觉组件已切到共享模块。
typealias Hairline = ReadBoardHairline
typealias VHairline = ReadBoardVHairline
typealias SectionLabel = ReadBoardSectionLabel
typealias RBadge = ReadBoardBadge

typealias QuietButtonStyle = ReadBoardQuietButtonStyle

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

/// 行 hover 按钮样式（左栏源行 / 设置行 / 列表行）：
/// hover 浮现 surface 圆角底；选中态交给 rbSelection 叠加，二者正交。
typealias RowHoverButtonStyle = ReadBoardRowHoverButtonStyle

extension ButtonStyle where Self == RowHoverButtonStyle {
    static var rowHover: RowHoverButtonStyle { RowHoverButtonStyle() }
}

/// 主行动胶囊按钮（「添加」「保存」等关键动作）：
/// 墨蓝实心 + onAccent 字，hover 微降明度，禁用 45% 透明。
/// 全 App 每屏至多一个主行动——视觉焦点纪律。
typealias PrimaryCapsuleButtonStyle = ReadBoardPrimaryCapsuleButtonStyle

extension ButtonStyle where Self == PrimaryCapsuleButtonStyle {
    static var primaryCapsule: PrimaryCapsuleButtonStyle { PrimaryCapsuleButtonStyle() }
}

/// 胶囊操作按钮（LLM 操作条等"可点动作"）：surface 底 + 圆角胶囊，
/// hover 时 accent 浅底浮现 + 文字 accent，图标+文字一组。比默认 bordered 按钮克制，
/// 比纯文字按钮有可点感。
typealias CapsuleButton = ReadBoardCapsuleButton

/// 状态横幅（同步中/管线状态/导入导出结果）：
/// surface 70% 底 + hairline 描边的通栏胶囊行——比裸文本行更像"系统状态"，
/// 又不打断页面流。
typealias StatusBanner<Content: View> = ReadBoardStatusBanner<Content>

extension View {
    /// 输入框底（搜索框/行内输入）：surface 圆角底 + hairline 描边；
    /// focused 时描边转墨蓝 40%——克制的焦点反馈，不用系统蓝环。
    func rbFieldBackground(focused: Bool = false) -> some View {
        self
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: RB.Radius.lg)
                    .fill(Color.rbSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RB.Radius.lg)
                    .strokeBorder(focused ? Color.rbAccent.opacity(0.4) : Color.rbHairline,
                                  lineWidth: RB.Line.hair)
            )
    }
}

/// 安静按钮样式的**无状态机版**（17:48 定案）：
/// 仅 ReadingView 使用——阅读区每篇文章销毁重建时，hover 追踪区 enter/exit 会
/// 在拆解窗口写 @State → AG cycle → 闪退（B3 静态按钮对照实验实锤稳定）。
/// 外观一致（无 hover 变色反馈，换来零状态机）。左栏/设置页保留带 hover 的 .quiet。
typealias StaticQuietButtonStyle = ReadBoardStaticQuietButtonStyle

extension ButtonStyle where Self == StaticQuietButtonStyle {
    static var staticQuiet: StaticQuietButtonStyle { StaticQuietButtonStyle() }
}

/// 胶囊操作按钮的**无状态机版**（ReadingView 专用，理由同上——B3 对照实验实锤稳定）。
typealias StaticCapsuleButton = ReadBoardStaticCapsuleButton

/// 纸墨分段选择器（替代原生 segmented control）：
/// surface 胶囊容器 + hairline 描边；选中段墨蓝浅底 + 墨蓝字 medium。
/// 原生 segmented 带系统蓝、视觉重，与纸墨系不搭——中栏筛选/阅读区视图切换统一用这个。
typealias RBSegmented<Item: Hashable> = ReadBoardSegmented<Item>

/// RSS 经典三半圆图标（标准 RSS feed 标识）
/// 左下原点 + 两道弧线， universally recognized 的 RSS 符号
typealias RSSIcon = ReadBoardRSSIcon

enum AudioPlaybackSettings {
    static let speeds: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]

    nonisolated static func clampedTime(_ value: Double, duration: Double) -> Double {
        guard value.isFinite else { return 0 }
        let upper = duration.isFinite && duration > 0 ? duration : max(value, 0)
        return min(max(value, 0), upper)
    }
}

/// AVPlayer 生命周期与观察器集中管理。播放器惰性创建：不点播放不会请求远程媒体。
@MainActor
final class AudioPlayerController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var isLoadingMetadata = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?

    private let audioURL: String
    private var asset: AVURLAsset?
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var metadataTask: Task<Void, Never>?
    private var preferredRate: Float = 1.0
    private var generation = 0

    init(audioURL: String) {
        self.audioURL = audioURL
    }

    func setPreferredRate(_ rate: Double) {
        let safeRate = AudioPlaybackSettings.speeds.contains(rate) ? rate : 1.0
        preferredRate = Float(safeRate)
        player?.defaultRate = preferredRate
        if isPlaying { player?.rate = preferredRate }
    }

    func togglePlay() {
        prepareIfNeeded()
        guard let player else { return }
        if player.timeControlStatus == .playing || player.rate > 0 {
            player.pause()
            isPlaying = false
        } else {
            errorMessage = nil
            isBuffering = true
            player.defaultRate = preferredRate
            player.play()
        }
    }

    /// 只读取远程媒体元数据，用于提前显示总时长；不会创建 AVPlayer 或缓冲音频正文。
    func preloadMetadata() {
        guard duration <= 0, metadataTask == nil, let asset = resolveAsset() else { return }
        let currentGeneration = generation
        isLoadingMetadata = true
        metadataTask = Task { [weak self] in
            do {
                let loadedDuration = try await asset.load(.duration)
                guard !Task.isCancelled, let self,
                      self.generation == currentGeneration,
                      self.asset === asset else { return }
                let seconds = loadedDuration.seconds
                if seconds.isFinite && seconds > 0 { self.duration = seconds }
            } catch is CancellationError {
                // 切换文章时正常取消。
            } catch {
                // 元数据读取失败不代表音频不能播放；点击播放后仍由 AVPlayer 重试。
            }
            guard let self, self.generation == currentGeneration else { return }
            self.metadataTask = nil
            self.isLoadingMetadata = false
        }
    }

    func skip(by seconds: Double) {
        prepareIfNeeded()
        seek(to: currentTime + seconds)
    }

    func seek(to seconds: Double) {
        prepareIfNeeded()
        guard let player else { return }
        let target = AudioPlaybackSettings.clampedTime(seconds, duration: duration)
        currentTime = target
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: CMTime(seconds: 0.25, preferredTimescale: 600),
            toleranceAfter: CMTime(seconds: 0.25, preferredTimescale: 600))
    }

    func cleanup() {
        generation += 1
        metadataTask?.cancel()
        metadataTask = nil
        player?.currentItem?.cancelPendingSeeks()
        if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        asset = nil
        isPlaying = false
        isBuffering = false
        isLoadingMetadata = false
        currentTime = 0
        duration = 0
    }

    private func prepareIfNeeded() {
        guard player == nil else { return }
        guard let asset = resolveAsset() else { return }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        player.defaultRate = preferredRate
        self.player = player
        preloadMetadata()
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak player] time in
            MainActor.assumeIsolated {
                guard let self, let player else { return }
                self.updateState(player: player, time: time)
            }
        }
    }

    private func resolveAsset() -> AVURLAsset? {
        if let asset { return asset }
        guard let url = URL(string: audioURL), let scheme = url.scheme,
              scheme == "http" || scheme == "https" else {
            errorMessage = "媒体地址无效"
            return nil
        }
        let newAsset = AVURLAsset(url: url)
        asset = newAsset
        return newAsset
    }

    private func updateState(player: AVPlayer, time: CMTime) {
        let seconds = time.seconds
        if seconds.isFinite { currentTime = max(0, seconds) }
        if let item = player.currentItem {
            let itemDuration = item.duration.seconds
            if itemDuration.isFinite && itemDuration > 0 { duration = itemDuration }
            if item.status == .failed {
                errorMessage = item.error?.localizedDescription ?? player.error?.localizedDescription ?? "媒体加载失败"
            }
        }
        isPlaying = player.timeControlStatus == .playing
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }
}

/// 播客播放器：自定义纸墨控制条 + AVPlayer 播放引擎。
/// 支持拖动进度、15 秒回退、30 秒前进、倍速、缓冲及失败提示；MP3/MP4 共用。
struct AudioPlayerView: View {
    let audioUrl: String
    let title: String
    @StateObject private var controller: AudioPlayerController
    @AppStorage("player.playbackRate") private var playbackRate: Double = 1.0
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    init(audioUrl: String, title: String) {
        self.audioUrl = audioUrl
        self.title = title
        _controller = StateObject(wrappedValue: AudioPlayerController(audioURL: audioUrl))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button { controller.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.staticQuiet)
                .help("后退 15 秒")

                Button { controller.togglePlay() } label: {
                    Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(Color.rbAccent)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .help(controller.isPlaying ? "暂停" : "播放")

                Button { controller.skip(by: 30) } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.staticQuiet)
                .help("前进 30 秒")

                VStack(spacing: 1) {
                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubTime : controller.currentTime },
                            set: { scrubTime = $0 }
                        ),
                        in: 0...max(controller.duration, 1),
                        onEditingChanged: { editing in
                            if editing {
                                scrubTime = controller.currentTime
                                isScrubbing = true
                            } else {
                                isScrubbing = false
                                controller.seek(to: scrubTime)
                            }
                        }
                    )
                    .tint(Color.rbAccent)
                    .disabled(controller.duration <= 0)
                    .frame(height: 24)

                    HStack {
                        Text(Self.formatTime(isScrubbing ? scrubTime : controller.currentTime))
                        Spacer()
                        Text("−" + Self.formatTime(max(0, controller.duration - (isScrubbing ? scrubTime : controller.currentTime))))
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.rbText3)
                }
                // 以 Slider 轨道而不是“轨道 + 时间”的整体中心与播放按钮对齐。
                .alignmentGuide(VerticalAlignment.center) { _ in 12 }

                if controller.isBuffering || controller.isLoadingMetadata {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16)
                        .help(controller.isLoadingMetadata ? "正在读取音频时长" : "正在缓冲")
                }

                Menu {
                    ForEach(AudioPlaybackSettings.speeds, id: \.self) { rate in
                        Button {
                            playbackRate = rate
                            controller.setPreferredRate(rate)
                        } label: {
                            if playbackRate == rate {
                                Label(Self.formatRate(rate), systemImage: "checkmark")
                            } else {
                                Text(Self.formatRate(rate))
                            }
                        }
                    }
                } label: {
                    Text(Self.formatRate(playbackRate))
                        .font(.system(size: 11, weight: .medium))
                        .frame(minWidth: 36)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("播放速度")
            }

            if let error = controller.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Color.rbScoreLow)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.rbSurface)
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
        .accessibilityLabel("\(title) 播放器")
        .onAppear {
            controller.setPreferredRate(playbackRate)
            controller.preloadMetadata()
        }
        .onChange(of: playbackRate) { _, rate in controller.setPreferredRate(rate) }
        .onDisappear { controller.cleanup() }
    }

    nonisolated static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    nonisolated static func formatRate(_ rate: Double) -> String {
        if rate == floor(rate) { return "\(Int(rate))×" }
        let decimals = rate * 10 == floor(rate * 10) ? 1 : 2
        return String(format: "%.*f×", decimals, rate)
    }
}

/// YouTube video player using yt-dlp -g (URL extraction only, no download) + AVPlayer.
/// yt-dlp -g returns direct stream URL in ~0.5s; AVPlayer streams directly from YouTube CDN.
/// WKWebView iframe embed is blocked by YouTube on macOS (Error 152/153 regardless of UA/Origin).
struct YouTubePlayerView: View {
    let videoId: String
    let title: String

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
    private let playbackTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: RB.Radius.lg)
                    .fill(Color.black)
                if hasStartedPlayback, let player {
                    AVPlayerViewRepresentable(player: player)
                        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
                } else {
                    YouTubeThumbnailView(videoId: videoId)
                        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
                }

                if let err = loadError, player == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(Color.yellow.opacity(0.7))
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 8)
                        Button("重试") { requestPlay() }
                            .font(.system(size: 12))
                            .foregroundStyle(Color.rbAccent)
                    }
                    .padding(16)
                    .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: RB.Radius.md))
                } else if !hasStartedPlayback {
                    Button {
                        requestPlay()
                    } label: {
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
                        .background(.black.opacity(0.34), in: RoundedRectangle(cornerRadius: RB.Radius.md))
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
                                .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 5))
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
                    Button {
                        togglePlay()
                    } label: {
                        Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.rbAccent)
                    }
                    .buttonStyle(.plain)
                }

                if player != nil || duration > 0 {
                    VStack(spacing: 4) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.rbBg)
                                    .frame(height: 4)
                                Capsule()
                                    .fill(Color.rbAccent)
                                    .frame(width: duration > 0 ? geo.size.width * CGFloat(currentTime / duration) : 0, height: 4)
                            }
                        }
                        .frame(height: 4)
                        HStack {
                            Text(formatTime(currentTime))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.rbText3)
                            Spacer()
                            Text(formatTime(duration))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.rbText3)
                        }
                    }
                }

                Button {
                    if let url = URL(string: "https://www.youtube.com/watch?v=\(videoId)") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.rbText3)
                }
                .buttonStyle(.plain)
                .help("Open in browser")

                Spacer()
            }
        }
        .padding(12)
        .background(Color.rbSurface)
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
        .onReceive(playbackTimer) { _ in
            refreshPlaybackState()
        }
        .onAppear { schedulePreload() }
        .onDisappear { cleanup() }
    }

    private func schedulePreload() {
        loadTask?.cancel()
        loadTask = Task {
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
                try Task.checkCancellation()
                // 这里只预解析并缓存直链，不提前创建 AVPlayer。AVPlayer.preroll
                // 在 status 尚未 readyToPlay 时会抛 Objective-C 异常。
                let url = try await YouTubeStreamResolver.resolve(videoId: videoId)
                try Task.checkCancellation()
                resolvedStreamURL = url
                duration = YouTubeStreamMetadata.durationHint(from: url)
            } catch {
                // 快速切换文章时正常取消。
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
                url = try await YouTubeStreamResolver.resolve(videoId: videoId)
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
        guard let p = player else { return }
        currentTime = p.currentTime().seconds
        if let item = p.currentItem {
            duration = YouTubeStreamMetadata.normalizedDuration(item.duration.seconds)
        }
        isPlaying = p.rate > 0
    }

    private func togglePlay() {
        guard let p = player else { return }
        hasStartedPlayback = true
        if isPlaying { p.pause() } else { p.play() }
        isPlaying = p.rate > 0
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "--:--" }
        let total = Int(sec)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
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

private struct YouTubeThumbnailView: View {
    let videoId: String

    var body: some View {
        AsyncImage(url: thumbnailURL(named: "maxresdefault")) { phase in
            switch phase {
            case .success(let image):
                fitted(image)
            case .failure:
                AsyncImage(url: thumbnailURL(named: "hqdefault")) { fallbackPhase in
                    if let image = fallbackPhase.image {
                        fitted(image)
                    } else {
                        Color.black
                    }
                }
            default:
                Color.black
            }
        }
        .background(Color.black)
    }

    private func thumbnailURL(named name: String) -> URL? {
        URL(string: "https://i.ytimg.com/vi/\(videoId)/\(name).jpg")
    }

    private func fitted(_ image: Image) -> some View {
        image
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
    }
}

// MARK: - Bilibili 播放器

enum VideoPlayerPlatform: Equatable {
    case youtube
    case bilibili

    static func resolve(source: String) -> VideoPlayerPlatform {
        source.lowercased() == "bilibili" ? .bilibili : .youtube
    }
}

/// B站官方内嵌播放器。B站 DASH 音视频通常分轨且 CDN 要求 Referer/Cookie，
/// 不适合直接复用 YouTube 的 yt-dlp + AVPlayer 链路；WKWebView 只包住播放器这一小块。
struct BilibiliPlayerView: View {
    let bvid: String
    let title: String
    let pageURL: String

    var body: some View {
        VStack(spacing: 8) {
            BilibiliWebPlayer(bvid: bvid)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))

            HStack {
                Text(title)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.rbText3)
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
                        .foregroundStyle(Color.rbText3)
                }
                .buttonStyle(.plain)
                .help("在浏览器中打开")
            }
        }
        .padding(12)
        .background(Color.rbSurface)
        .clipShape(RoundedRectangle(cornerRadius: RB.Radius.lg))
    }
}

/// SwiftUI 保留 BVID 作为唯一状态；WKWebView 仅负责官方播放器的创建、更新和销毁。
private struct BilibiliWebPlayer: NSViewRepresentable {
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
        guard var components = URLComponents(string: "https://player.bilibili.com/player.html") else { return }
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

/// AVPlayerView wrapper for SwiftUI on macOS
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
