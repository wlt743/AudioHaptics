import Foundation

/// 门面：把「分析」和「播放」串起来。
///
/// ```swift
/// let haptics = AudioHaptics()
/// haptics.attach(url: localAudioURL)            // 换曲
/// haptics.positionProvider = { player.currentTime }  // 接你播放器的时间
/// haptics.start()                              // 开始播
/// haptics.pause()                              // 暂停
/// ```
public final class AudioHaptics {
    public let player: HapticPlayer
    private var task: Task<Void, Never>?

    public var state: HapticPlayer.State { player.state }
    public var tuning: HapticTuning {
        get { player.tuning }
        set { player.tuning = newValue; player.refreshOnsets() }
    }

    public var positionProvider: (() -> TimeInterval)? {
        get { player.positionProvider }
        set { player.positionProvider = newValue }
    }

    public init(tuning: HapticTuning = .standard) {
        player = HapticPlayer()
        player.tuning = tuning
    }

    /// 换曲分析。远程音频请先下载到本地——`AVAssetReader` 读不了流式响应。
    public func attach(url: URL) {
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            let analysis = HapticAnalyzer.analyse(url: url)
            await MainActor.run {
                self?.player.load(analysis: analysis)
            }
        }
    }

    public func start() { player.start() }
    public func pause() { player.pause() }
    public func seek(to position: TimeInterval) { player.seek(to: position) }
    public func playTest() { player.playTest() }
}
