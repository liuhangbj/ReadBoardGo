import AVFoundation
import Combine
import SwiftUI

private enum ReadBoardAudioPlaybackSettings {
    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    nonisolated static func clampedTime(_ value: Double, duration: Double) -> Double {
        guard value.isFinite else { return 0 }
        let upper = duration.isFinite && duration > 0 ? duration : max(value, 0)
        return min(max(value, 0), upper)
    }
}

@MainActor
private final class ReadBoardAudioPlayerController: ObservableObject {
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
    private var preferredRate: Float = 1
    private var generation = 0

    init(audioURL: String) {
        self.audioURL = audioURL
    }

    func setPreferredRate(_ rate: Double) {
        let safeRate = ReadBoardAudioPlaybackSettings.speeds.contains(rate) ? rate : 1
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
                // 元数据失败不代表音频不能播放，点击播放后仍由 AVPlayer 重试。
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
        let target = ReadBoardAudioPlaybackSettings.clampedTime(seconds, duration: duration)
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
                errorMessage = item.error?.localizedDescription
                    ?? player.error?.localizedDescription
                    ?? "媒体加载失败"
            }
        }
        isPlaying = player.timeControlStatus == .playing
        isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }
}

/// Core 复制基线中的播客播放器：纸墨控制条与 AVPlayer 播放引擎原样共享。
public struct ReadBoardAudioPlayerView: View {
    public let audioUrl: String
    public let title: String
    @StateObject private var controller: ReadBoardAudioPlayerController
    @AppStorage("player.playbackRate") private var playbackRate: Double = 1
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0

    public init(audioUrl: String, title: String) {
        self.audioUrl = audioUrl
        self.title = title
        _controller = StateObject(
            wrappedValue: ReadBoardAudioPlayerController(audioURL: audioUrl))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Button { controller.skip(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ReadBoardStaticQuietButtonStyle())
                .help("后退 15 秒")

                Button { controller.togglePlay() } label: {
                    Image(systemName: controller.isPlaying
                        ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(ReadBoardDesign.C.accent)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .help(controller.isPlaying ? "暂停" : "播放")

                Button { controller.skip(by: 30) } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 15))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ReadBoardStaticQuietButtonStyle())
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
                    .tint(ReadBoardDesign.C.accent)
                    .disabled(controller.duration <= 0)
                    .frame(height: 24)

                    HStack {
                        Text(Self.formatTime(
                            isScrubbing ? scrubTime : controller.currentTime))
                        Spacer()
                        Text("−" + Self.formatTime(max(
                            0,
                            controller.duration
                                - (isScrubbing ? scrubTime : controller.currentTime))))
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(ReadBoardDesign.C.text3)
                }
                .alignmentGuide(VerticalAlignment.center) { _ in 12 }

                if controller.isBuffering || controller.isLoadingMetadata {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16)
                        .help(controller.isLoadingMetadata
                            ? "正在读取音频时长" : "正在缓冲")
                }

                Menu {
                    ForEach(ReadBoardAudioPlaybackSettings.speeds, id: \.self) { rate in
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
                    .foregroundStyle(ReadBoardDesign.C.scoreLow)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(ReadBoardDesign.C.surface)
        .clipShape(RoundedRectangle(cornerRadius: ReadBoardDesign.Radius.lg))
        .accessibilityLabel("\(title) 播放器")
        .onAppear {
            controller.setPreferredRate(playbackRate)
            controller.preloadMetadata()
        }
        .onChange(of: playbackRate) { _, rate in
            controller.setPreferredRate(rate)
        }
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
