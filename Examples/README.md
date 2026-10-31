# 接入示例

最小可运行的接入代码，假设你已经有播放器和本地音频文件。

```swift
import AVFoundation
import AudioHaptics

final class PlayerWithHaptics: ObservableObject {
    private let player = AVPlayer()
    private let haptics = AudioHaptics(tuning: .extreme)

    init() {
        // 播放器的时间源交给震动层，两者必须同步
        haptics.positionProvider = { [weak self] in
            guard let self, let item = self.player.currentItem else { return 0 }
            let seconds = CMTimeGetSeconds(item.currentTime())
            return seconds.isFinite ? max(0, seconds) : 0
        }
    }

    /// 播放本地文件：分析完成后自动开始
    func play(localFile: URL) {
        haptics.attach(url: localFile)
        player.replaceCurrentItem(with: AVPlayerItem(url: localFile))
        player.play()
        haptics.start()
    }

    func pause() {
        player.pause()
        haptics.pause()
    }

    /// 远程音频：先下载到本地再分析（AVAssetReader 读不了流）
    func play(remote: URL) async throws {
        let (temp, _) = try await URLSession.shared.download(from: remote)
        let ext = remote.pathExtension.isEmpty ? "mp3" : remote.pathExtension
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try FileManager.default.moveItem(at: temp, to: local)
        play(localFile: local)
    }
}
```

## 手感面板

```swift
Slider(value: Binding(
    get: { haptics.tuning.floor },
    set: { haptics.tuning.floor = $0 }
), in: 0...0.6)
```

每次改 `tuning` 后调一次 `refreshOnsets()`（`AudioHaptics.tuning` 的 setter 已经做了）。
