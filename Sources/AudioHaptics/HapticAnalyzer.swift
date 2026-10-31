import Foundation
import AVFoundation

/// 音频 → 触觉时间轴。
///
/// 分两步：
/// 1. `analyse` 把音频解码成固定帧率（默认 60fps）的特征序列；
/// 2. `derive` 用参数把这些帧变成重击点。
///
/// 分成两步的好处：调整手感时只重算第 2 步，不用重新解码音频。
public enum HapticAnalyzer {

    /// 一帧的原始特征
    public struct Frame: Sendable {
        /// 频谱通量：高频/低频各频段相对上一帧的正向增长，起音越猛值越大
        public let flux: Float
        /// <120Hz 能量（鼓、贝斯）
        public let low: Float
        /// 120Hz~2kHz 能量（人声、乐器）
        public let mid: Float
        /// >2kHz 能量（镲、嘶声、火焰等宽带噪声）
        public let high: Float
        /// 音色亮度 0…1
        public let brightness: Float
        /// 噪声性 0…1：越高越像噪声，用于把锐度推上去
        public let noisiness: Float
    }

    /// 一个重击点
    public struct Onset: Sendable {
        public let time: TimeInterval
        public let strength: Float
        public let sharpness: Float
        /// 是否落在 BPM 节拍网格上（这类点会更重）
        public let accented: Bool
    }

    /// 分析结果：帧序列 + 整曲响度基准
    public struct Analysis: Sendable {
        public let frames: [Frame]
        /// 响度 95 分位，用来把谱段响度归一化，让副歌顶到满
        public let reference: Float
    }

    public static let defaultFrameRate: Double = 60

    // MARK: - 第一步：解码与特征提取

    /// 分析本地音频文件。远程 URL 请先下载到本地（见 README「为什么必须先落盘」）。
    public static func analyse(url: URL,
                               frameRate: Double = defaultFrameRate) -> Analysis {
        let sampleRate = 22050.0
        let bucket = Int(sampleRate / frameRate)
        guard bucket > 0,
              let (reader, output) = try? makeReader(url: url, sampleRate: sampleRate) else {
            return Analysis(frames: [], reference: 0.001)
        }

        let lowAlpha: Float = 0.034   // 一阶低通，约 120Hz
        let highAlpha: Float = 0.35   // 一阶低通，约 2kHz，用差值取高频
        var lowLP: Float = 0
        var highLP: Float = 0
        var lowSum: Float = 0
        var highSum: Float = 0
        var totalSum: Float = 0
        var count = 0
        var previousLow: Float = 0
        var previousHigh: Float = 0
        var frames: [Frame] = []

        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            let status = CMBlockBufferGetDataPointer(block, atOffset: 0,
                                                     lengthAtOffsetOut: nil,
                                                     totalLengthOut: &length,
                                                     dataPointerOut: &pointer)
            guard status == noErr, let pointer else { continue }
            let samples = length / MemoryLayout<Int16>.size
            let buffer = UnsafeRawPointer(pointer).assumingMemoryBound(to: Int16.self)

            for i in 0..<samples {
                let x = Float(buffer[i]) / 32768
                lowLP += lowAlpha * (x - lowLP)
                highLP += highAlpha * (x - highLP)
                let high = x - highLP
                let mid = highLP - lowLP
                totalSum += x * x
                lowSum += lowLP * lowLP
                highSum += high * high
                count += 1

                if count >= bucket {
                    let low = (lowSum / Float(count)).squareRoot()
                    let highRMS = (highSum / Float(count)).squareRoot()
                    let midRMS = (max(totalSum - lowSum - highSum, 0) / Float(count)).squareRoot()

                    // 各频段的正向增长之和，近似频谱通量
                    let delta = max(low - previousLow, 0)
                        + max(highRMS - previousHigh, 0) * 1.4
                        + midRMS * 0.2

                    let total = low + midRMS + highRMS
                    let brightness = total > 0.0001
                        ? min(1, (highRMS * 1.6 + midRMS * 0.6) / total) : 0
                    let noisiness = total > 0.0001
                        ? min(1, highRMS / max(low, 0.0002) * 0.35) : 0

                    frames.append(Frame(flux: delta, low: low, mid: midRMS,
                                        high: highRMS, brightness: brightness,
                                        noisiness: noisiness))
                    previousLow = low
                    previousHigh = highRMS
                    totalSum = 0
                    lowSum = 0
                    highSum = 0
                    count = 0
                }
            }
        }

        _ = reader
        guard !frames.isEmpty else { return Analysis(frames: [], reference: 0.001) }

        let loudness = frames.map {
            Double($0.low) * 0.6 + Double($0.mid) * 0.25 + Double($0.high) * 0.5
        }.sorted()
        let reference = Float(max(loudness[Int(Double(loudness.count - 1) * 0.95)], 0.0005))
        return Analysis(frames: frames, reference: reference)
    }

    // MARK: - 第二步：参数 → 重击点

    public static func derive(analysis: Analysis,
                              tuning: HapticTuning,
                              frameRate: Double = defaultFrameRate) -> [Onset] {
        let frames = analysis.frames
        guard frames.count > 8 else { return [] }

        let flux = frames.map { $0.flux }
        let mean = flux.reduce(0, +) / Float(flux.count)
        let variance = flux.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(flux.count)
        let std = max(variance.squareRoot(), 0.0001)
        let threshold = mean + Float(tuning.sensitivity) * std

        // 自相关估 BPM，用于给落在节拍上的点加权
        let minLag = Int(frameRate * 60 / 200)
        let maxLag = Int(frameRate * 60 / 60)
        var bestLag = 0
        var bestScore: Float = 0
        if maxLag > minLag, flux.count > maxLag * 2 {
            for lag in minLag...maxLag {
                var score: Float = 0
                var i = 0
                while i + lag < flux.count {
                    score += flux[i] * flux[i + lag]
                    i += 1
                }
                if score > bestScore { bestScore = score; bestLag = lag }
            }
        }
        let beatPeriod = bestLag > 0 ? Double(bestLag) / frameRate : 0

        var result: [Onset] = []
        var lastTime: TimeInterval = -1
        for i in 3..<flux.count {
            let current = flux[i]
            guard current > threshold else { continue }
            let time = Double(i) / frameRate
            guard time - lastTime > tuning.minGap else { continue }

            let strength = Float(min(1, current / (threshold * 2.2 + 0.0001)))
            let frame = frames[i]
            let sharpness = Float(min(1, max(0.3, 0.45 + Double(frame.brightness) * 0.55)))

            var accented = false
            if beatPeriod > 0 {
                let phase = time.truncatingRemainder(dividingBy: beatPeriod)
                accented = min(phase, beatPeriod - phase) < 0.07
            }
            result.append(Onset(time: time, strength: strength,
                                sharpness: sharpness, accented: accented))
            lastTime = time
        }
        return result
    }

    // MARK: - 解码

    private static func makeReader(url: URL,
                                   sampleRate: Double) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else {
            throw NSError(domain: "AudioHaptics", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "没有音频轨道"])
        }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw NSError(domain: "AudioHaptics", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "无法添加音频输出"])
        }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "AudioHaptics", code: 3)
        }
        return (reader, output)
    }
}
