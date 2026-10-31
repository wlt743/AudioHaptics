# AudioHaptics

把音乐变成触感。跟着音频的**响度和音色**走，不是简单跟着节拍敲。

iOS 13+ / iPhone 8 以上（CoreHaptics）。用 Swift Package Manager 引入：

```swift
.package(url: "https://github.com/wlt743/AudioHaptics.git", from: "1.0.0")
```

## 效果

- 底鼓 → 低频、低锐度 → "咚"
- 镲片、火焰、嘶声 → 高频噪声、高锐度 → "呲"
- 副歌 → 响度顶满 → 震感压到马达上限

这就是「跟着音色震动」和「跟着节拍敲」的区别。

## 用法

```swift
import AudioHaptics

let haptics = AudioHaptics(tuning: .extreme)

// 1. 换曲：传入**本地**音频文件
haptics.attach(url: localAudioURL)

// 2. 接你播放器的时间源（秒）
haptics.positionProvider = { [weak player] in player?.currentTime().seconds ?? 0 }

// 3. 跟着播放状态走
haptics.start()
haptics.pause()
haptics.seek(to: time)
```

面板里给用户调手感：

```swift
haptics.tuning = .intense      // 预设
haptics.tuning.floor = 0.4     // 打底强度
```

## 算法

> 设计取舍、每个参数的来历、走过的弯路，详见 **[docs/DESIGN.md](docs/DESIGN.md)**。

```
音频 ──解码──> 22kHz 单声道 PCM
         │
         ├── 一阶低通(120Hz) ─> low   能量
         ├── 一阶低通(2kHz)  ─> high  能量（高频噪声、镲、嘶声）
         ├── 差值            ─> mid   能量
         └── 各频段正向增量之和 ─> flux 频谱通量
                    │
                    ▼
            固定 60fps 的特征帧
                    │
        ┌───────────┴───────────┐
        ▼                       ▼
   连续层                    离散重击
   intensity ← 响度          threshold = mean + k·std
   sharpness ← 音色          落在 BPM 网格上的点加重
        │                       │
        └────────┬──────────────┘
                 ▼
           CoreHaptics
```

**为什么分两步**：第 1 步只算原始特征（每帧 6 个 float），第 2 步用参数推导重击点。
用户拖滑杆时只重算第 2 步，不用重新解码音频，可以实时生效。

## 参数

| 字段 | 含义 | 建议范围 |
|---|---|---|
| `sensitivity` | 挑点门槛系数，越大越挑 | 0.6 ~ 3.0 |
| `minGap` | 相邻重击最小间隔（秒），太小会糊 | 0.05 ~ 0.30 |
| `strength` | 重击力度倍率 | 0.5 ~ 2.0 |
| `sharpness` | 锐度基准，越高越脆 | 0.4 ~ 1.0 |
| `bed` | 连续层整体权重，0 为纯离散打击 | 0 ~ 1.0 |
| `floor` | 连续层打底，安静段落的基础震动 | 0 ~ 0.6 |

内置四档：`.soft` / `.standard` / `.intense` / `.extreme`。

## 踩过的坑

**1. 远程音频必须落盘再分析**
`AVAssetReader` 直接读 HTTP 流经常一个采样都解不出来。先 `URLSession` 下载到临时文件再解码。

**2. 临时文件必须保留原扩展名**
存成 `.bin` 时 `AVURLAsset` 不认识容器格式，`tracks(withMediaType: .audio)` 直接返回空——表现是"分析出 0 帧"。

**3. 连续事件的基础强度不能设 0**
`hapticIntensityControl` 是在事件基础强度上做乘法，基础为 0 的话乘多少都是 0，永远震不动。

**4. 重击必须预排，不能现场造播放器**
每个起音现场 `makePlayer` + `start` 会引入几十毫秒抖动，节奏立刻糊掉。提前把未来 4 秒的事件塞进一个 pattern。

**5. 归一化别二次放大**
`bed` 再乘一个系数很容易让所有档位饱和到 1.0，表现为"怎么调都一样糊"。`bed` 直接当 0…1 权重用。

**6. `CADisplayLink` 的 target 必须是 NSObject**
纯 Swift 类挂 `@objc` 方法，选择器永远调不到，表现为"分析全对但一点不震"。

## 服务端方案

`server/analyze.py` 是一份纯 numpy 的参考实现：解出 PCM、算 STFT、输出每帧的
`[响度, 亮度, 噪声性]`，可用来在服务端预生成时间轴并缓存，客户端只负责按时间点播。
好处是不用下载整首歌、不耗手机 CPU、算法可以上更重的模型。

## License

MIT
