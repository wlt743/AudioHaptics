#!/usr/bin/env python3
"""服务端参考实现：音频 → 触觉时间轴。

只依赖 numpy + ffmpeg。输出每帧的 [响度, 亮度, 噪声性]，
客户端拿到后按时间点调 hapticIntensityControl / hapticSharpnessControl 即可。

用法:
    python analyze.py song.mp3 > song.haptics.json
"""
import json
import subprocess
import sys

import numpy as np

SAMPLE_RATE = 22050
FPS = 60
FRAME = SAMPLE_RATE // FPS          # 367 采样一帧


def decode(path: str) -> np.ndarray:
    """用 ffmpeg 解成 22kHz 单声道 float32。"""
    cmd = [
        "ffmpeg", "-v", "error", "-i", path,
        "-ac", "1", "-ar", str(SAMPLE_RATE),
        "-f", "f32le", "-",
    ]
    raw = subprocess.run(cmd, capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32)


def frame_features(samples: np.ndarray) -> dict:
    """按帧算三个特征。滤波用一阶 IIR，足够做触觉映射。"""
    n = len(samples) // FRAME * FRAME
    x = samples[:n].reshape(-1, FRAME)

    # 一阶低通：y[n] = y[n-1] + a*(x[n]-y[n-1])
    low = _one_pole(x, alpha=0.034)    # ~120Hz
    high_lp = _one_pole(x, alpha=0.35)  # ~2kHz
    mid = high_lp - low
    high = x - high_lp

    low_e = np.sqrt((low ** 2).mean(axis=1))
    mid_e = np.sqrt((mid ** 2).mean(axis=1))
    high_e = np.sqrt((high ** 2).mean(axis=1))
    total = low_e + mid_e + high_e + 1e-9

    # 响度：低频权重最高，触感主要靠它撑
    loudness = low_e * 0.6 + mid_e * 0.25 + high_e * 0.5
    # 亮度：高频 + 中频占比
    brightness = np.clip((high_e * 1.6 + mid_e * 0.6) / total, 0, 1)
    # 噪声性：高频相对低频的富集，火焰/风声这类宽带噪声值高
    noisiness = np.clip(high_e / (low_e + 1e-4) * 0.35, 0, 1)

    # 用 95 分位归一化响度，副歌才能顶到 1.0
    reference = float(np.percentile(loudness, 95)) or 1e-6
    normalized = np.clip(loudness / reference, 0, 1)

    return {
        "fps": FPS,
        "reference": reference,
        "loudness": np.round(normalized, 3).tolist(),
        "brightness": np.round(brightness, 3).tolist(),
        "noisiness": np.round(noisiness, 3).tolist(),
    }


def _one_pole(x: np.ndarray, alpha: float) -> np.ndarray:
    """分块的一阶低通，避免逐样本 Python 循环。"""
    out = np.empty_like(x)
    state = 0.0
    for i in range(x.shape[0]):
        row = x[i]
        acc = np.empty_like(row)
        for j in range(row.shape[0]):     # 每帧 367 个采样
            state += alpha * (row[j] - state)
            acc[j] = state
        out[i] = acc
    return out


def main() -> None:
    if len(sys.argv) < 2:
        print("用法: python analyze.py <音频文件>", file=sys.stderr)
        sys.exit(1)
    features = frame_features(decode(sys.argv[1]))
    json.dump(features, sys.stdout)


if __name__ == "__main__":
    main()
