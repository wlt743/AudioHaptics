import Foundation
import AVFoundation
import CoreHaptics
import QuartzCore

/// 把重击点播成触感。
///
/// 两条通路：
/// - **离散重击**：提前把未来几秒的起音点排进一个 pattern，按绝对时间触发。
///   逐个现场构造播放器会有几十毫秒抖动，节奏就糊了，所以必须预排。
/// - **连续层**：一个长驻的 continuous 事件，每帧推 intensity / sharpness，
///   让声音的响度和音色连续地变成触感。
public final class HapticPlayer {

    public enum State {
        case idle
        case running
        case unsupported
    }

    public private(set) var state: State = .idle
    public var tuning: HapticTuning = .standard {
        didSet { onTuningChanged?() }
    }
    /// 播放位置（秒）。接入方提供，保证和音频同一个时间源。
    public var positionProvider: (() -> TimeInterval)?
    /// 手感变化时回调，接入方据此重新推导重击点
    public var onTuningChanged: (() -> Void)?

    private let engine: CHHapticEngine?
    private var bedPlayer: CHHapticAdvancedPatternPlayer?
    private var accentPlayer: CHHapticAdvancedPatternPlayer?
    private var link: CADisplayLink?

    private var frames: [HapticAnalyzer.Frame] = []
    private var onsets: [HapticAnalyzer.Onset] = []
    private var reference: Float = 0.001
    private var windowStart: TimeInterval = -1
    private var lastLevel: Float = -1
    private var lastSharpness: Float = -1

    private let window: TimeInterval = 4.0
    private let loopDuration: TimeInterval = 2.0
    private let frameRate: Double

    public init(frameRate: Double = HapticAnalyzer.defaultFrameRate) {
        self.frameRate = frameRate
        if CHHapticEngine.capabilitiesForHardware().supportsHaptics {
            engine = try? CHHapticEngine()
            state = engine == nil ? .unsupported : .idle
            engine?.playsHapticsOnly = true
            engine?.isAutoShutdownEnabled = true
            engine?.resetHandler = { [weak self] in
                guard let engine = self?.engine else { return }
                DispatchQueue.main.async { try? engine.start() }
            }
        } else {
            engine = nil
            state = .unsupported
        }
    }

    // MARK: - 生命周期

    /// 换曲：传入已分析好的时间轴
    public func load(analysis: HapticAnalyzer.Analysis) {
        frames = analysis.frames
        reference = analysis.reference
        onsets = HapticAnalyzer.derive(analysis: analysis, tuning: tuning, frameRate: frameRate)
        windowStart = -1
        lastLevel = -1
        lastSharpness = -1
    }

    /// 参数变化后重新推导重击点
    public func refreshOnsets() {
        let analysis = HapticAnalyzer.Analysis(frames: frames, reference: reference)
        onsets = HapticAnalyzer.derive(analysis: analysis, tuning: tuning, frameRate: frameRate)
        windowStart = -1
        scheduleAccents(force: true)
    }

    public func start() {
        guard let engine else { return }
        try? engine.start()
        startBed()
        startLoop()
        scheduleAccents(force: true)
        state = .running
    }

    public func pause() {
        link?.invalidate()
        link = nil
        try? bedPlayer?.stop(atTime: CHHapticTimeImmediate)
        bedPlayer = nil
        try? accentPlayer?.stop(atTime: CHHapticTimeImmediate)
        accentPlayer = nil
        windowStart = -1
        state = .idle
    }

    public func seek(to position: TimeInterval) {
        scheduleAccents(force: true)
    }

    /// 单次测试震动（三连击）
    public func playTest() {
        guard let engine else { return }
        let events = (0..<3).map { index in
            CHHapticEvent(eventType: .hapticTransient,
                          parameters: [
                            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.9),
                          ],
                          relativeTime: Double(index) * 0.16)
        }
        guard let pattern = try? CHHapticPattern(events: events, parameters: []) else { return }
        try? engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
    }

    // MARK: - 播放器

    private func startBed() {
        guard bedPlayer == nil, let engine else { return }
        let event = CHHapticEvent(eventType: .hapticContinuous,
                                  parameters: [
                                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
                                  ],
                                  relativeTime: 0, duration: loopDuration)
        guard let pattern = try? CHHapticPattern(events: [event], parameters: []),
              let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
        player.loopEnabled = true
        try? player.start(atTime: CHHapticTimeImmediate)
        bedPlayer = player
    }

    private func scheduleAccents(force: Bool) {
        guard let engine, !onsets.isEmpty else { return }
        guard let position = positionProvider?(), position.isFinite, position >= 0 else { return }
        if !force, windowStart >= 0, position - windowStart < window - 1.2 { return }

        let upcoming = onsets.filter { $0.time >= position - 0.02 && $0.time < position + window }
        windowStart = position
        guard !upcoming.isEmpty else { accentPlayer = nil; return }

        let events = upcoming.map { onset -> CHHapticEvent in
            let base = Double(onset.strength) * tuning.strength * 1.6
            let floorValue = tuning.floor > 0.4 ? 0.94 : 0.8
            let value = Float(onset.accented ? 1.0 : min(1.0, max(floorValue, base)))
            let sharpness = Float(min(1.0, max(0.3,
                Double(onset.sharpness) + (tuning.sharpness - 0.75))))
            return CHHapticEvent(eventType: .hapticTransient,
                                 parameters: [
                                    CHHapticEventParameter(parameterID: .hapticIntensity, value: value),
                                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
                                 ],
                                 relativeTime: max(0, onset.time - position))
        }
        try? accentPlayer?.stop(atTime: CHHapticTimeImmediate)
        guard let pattern = try? CHHapticPattern(events: events, parameters: []),
              let player = try? engine.makeAdvancedPlayer(with: pattern) else {
            accentPlayer = nil
            return
        }
        try? player.start(atTime: CHHapticTimeImmediate)
        accentPlayer = player
    }

    // MARK: - 逐帧推包络

    private func startLoop() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick() {
        guard let position = positionProvider?(), position.isFinite, position >= 0 else { return }

        if windowStart < 0 || position - windowStart > window - 1.2 {
            scheduleAccents(force: true)
        }

        guard let bedPlayer, !frames.isEmpty else { return }
        let index = Int(position * frameRate)
        guard index >= 0, index < frames.count else { return }
        let frame = frames[index]

        // 音色 → 锐度：高频噪声（火焰、嘶声、镲）给高锐度，低频给低锐度
        let sharpness = Float(min(1.0, max(0.15,
            Double(frame.noisiness) * 0.75 + Double(frame.brightness) * 0.35
            + tuning.sharpness - 0.75)))

        // 响度 → 强度，带打底
        let floorLevel = Float(tuning.floor)
        let loudness = Float(Double(frame.low) * 0.6 + Double(frame.mid) * 0.25
                             + Double(frame.high) * 0.5)
        let normalized = min(1, loudness / max(reference, 0.0001))
        let level = min(1.0, (floorLevel + (1 - floorLevel) * normalized) * Float(tuning.bed))

        guard abs(level - lastLevel) > 0.015 || abs(sharpness - lastSharpness) > 0.05 else { return }
        lastLevel = level
        lastSharpness = sharpness
        let parameters = [
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: level, relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: sharpness, relativeTime: 0),
        ]
        try? bedPlayer.sendParameters(parameters, atTime: CHHapticTimeImmediate)
    }
}
