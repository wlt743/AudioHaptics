import Foundation

/// 手感参数。所有字段都是 0…1 的比例（floor / bed 例外，见注释）。
public struct HapticTuning: Codable, Equatable, Sendable {
    /// 灵敏度：越大越挑，只保留最强的起音点
    public var sensitivity: Double = 1.2
    /// 相邻重击的最小间隔（秒）。太小会叠在一起发糊
    public var minGap: Double = 0.10
    /// 重击力度倍率
    public var strength: Double = 1.0
    /// 锐度基准 0…1：越高越"脆"，越低越"闷"
    public var sharpness: Double = 0.75
    /// 连续层整体权重 0…1：0 表示纯离散打击
    public var bed: Double = 0.7
    /// 连续层打底 0…1：安静段落也保留的基础震动
    public var floor: Double = 0.32

    public init(sensitivity: Double = 1.2,
                minGap: Double = 0.10,
                strength: Double = 1.0,
                sharpness: Double = 0.75,
                bed: Double = 0.7,
                floor: Double = 0.32) {
        self.sensitivity = sensitivity
        self.minGap = minGap
        self.strength = strength
        self.sharpness = sharpness
        self.bed = bed
        self.floor = floor
    }

    public static let standard = HapticTuning()

    /// 柔和：点少、偏闷、震动轻
    public static let soft = HapticTuning(sensitivity: 1.9, minGap: 0.14, strength: 0.9,
                                          sharpness: 0.5, bed: 0.45, floor: 0.14)

    /// 强烈：点多、偏脆
    public static let intense = HapticTuning(sensitivity: 0.85, minGap: 0.08, strength: 1.5,
                                             sharpness: 0.95, bed: 0.85, floor: 0.32)

    /// 超强：打底更实，重击压满马达
    public static let extreme = HapticTuning(sensitivity: 0.8, minGap: 0.07, strength: 1.75,
                                             sharpness: 1.0, bed: 1.0, floor: 0.46)
}
