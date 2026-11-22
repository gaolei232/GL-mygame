"""生成《城墙尸潮》的占位音效（程序化合成，无第三方素材）。

用法：
    python tools/sfx_gen.py

产物：art/assets/audio/sfx_*.wav（44.1kHz 单声道 16bit）。
这些都是占位音：等美术/音频真正的素材到位后，替换同名文件即可，
接线（view/audio_layer.gd）不需要改。

设计口径：
- 全部短促、干声、无混响——2.5D 俯视 + 大量重复音，混响会糊成一片。
- 同类音加 ±6% 随机音高（在 GDScript 里做），避免连发时像机关枪。
- 峰值统一 -3dBFS，响度靠 audio_layer 里的 db 偏移分轨控制。
"""

import math
import os
import wave

import numpy as np

SR = 44100
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                       "art", "assets", "audio")
RNG = np.random.RandomState(20261109)


def t_axis(seconds):
    return np.arange(int(SR * seconds)) / SR


def noise(n):
    return RNG.randn(n)


def lowpass(x, cutoff_hz):
    """一阶低通（单极点），够用且不会引入相位怪声。"""
    alpha = 1.0 - math.exp(-2.0 * math.pi * cutoff_hz / SR)
    y = np.zeros_like(x)
    acc = 0.0
    for i in range(len(x)):
        acc += alpha * (x[i] - acc)
        y[i] = acc
    return y


def env(seconds, attack=0.002, decay=0.05):
    t = t_axis(seconds)
    a = np.minimum(1.0, t / max(attack, 1e-4))
    return a * np.exp(-t / max(decay, 1e-4))


def sweep(seconds, f0, f1, kind="sine"):
    t = t_axis(seconds)
    f = np.linspace(f0, f1, len(t))
    phase = 2.0 * np.pi * np.cumsum(f) / SR
    if kind == "saw":
        return 2.0 * ((phase / (2 * np.pi)) % 1.0) - 1.0
    return np.sin(phase)


def normalize(x, peak_db=-3.0):
    peak = np.max(np.abs(x)) or 1.0
    target = 10 ** (peak_db / 20.0)
    return x / peak * target


def save(name, samples):
    data = normalize(samples)
    pcm = np.clip(data * 32767.0, -32768, 32767).astype("<i2")
    path = os.path.join(OUT_DIR, name)
    with wave.open(path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(SR)
        f.writeframes(pcm.tobytes())
    print("%-22s %6.1f KB  %.2fs" % (name, os.path.getsize(path) / 1024.0, len(samples) / SR))


def sfx_shot():
    d = 0.13
    n = noise(int(SR * d))
    body = sweep(d, 950, 280) * 0.55
    click = lowpass(n, 6000) * 0.45 * np.exp(-t_axis(d) / 0.008)
    return (body + click) * env(d, 0.001, 0.035)


def sfx_knife():
    d = 0.16
    n = noise(int(SR * d))
    hiss = (n - lowpass(n, 1200)) * 0.6
    return hiss * env(d, 0.004, 0.05)


def sfx_hit():
    d = 0.08
    n = lowpass(noise(int(SR * d)), 2500) * 0.6
    body = sweep(d, 240, 150) * 0.5
    return (n + body) * env(d, 0.001, 0.018)


def sfx_kill():
    d = 0.26
    n = lowpass(noise(int(SR * d)), 900) * 0.45
    body = sweep(d, 150, 60) * 0.7
    return (n + body) * env(d, 0.002, 0.07)


def sfx_repair():
    d = 0.2
    n = lowpass(noise(int(SR * d)), 3000) * 0.35
    body = sweep(d, 190, 120) * 0.6
    click = lowpass(noise(int(SR * d)), 7000) * 0.5 * np.exp(-t_axis(d) / 0.006)
    return (n + body + click) * env(d, 0.001, 0.045)


def sfx_buy():
    d = 0.28
    t = t_axis(d)
    a = np.sin(2 * np.pi * 880 * t) * np.exp(-t / 0.07)
    b = np.sin(2 * np.pi * 1320 * t) * np.exp(-np.clip(t - 0.05, 0, None) / 0.09)
    click = lowpass(noise(len(t)), 7000) * 0.25 * np.exp(-t / 0.004)
    return a * 0.6 + b * 0.5 + click


def sfx_loot():
    d = 0.34
    t = t_axis(d)
    a = np.sin(2 * np.pi * 1046 * t) * np.exp(-t / 0.09)
    b = np.sin(2 * np.pi * 1568 * t + 0.3) * np.exp(-np.clip(t - 0.06, 0, None) / 0.11)
    return a * 0.6 + b * 0.45


def sfx_breach():
    d = 0.75
    body = sweep(d, 85, 38) * 0.8
    n = lowpass(noise(int(SR * d)), 500) * 0.55
    return (body + n) * env(d, 0.004, 0.22)


def sfx_crystal():
    d = 0.42
    t = t_axis(d)
    a = np.sin(2 * np.pi * 1760 * t) * np.exp(-t / 0.08)
    b = np.sin(2 * np.pi * 2640 * t) * np.exp(-t / 0.05) * 0.4
    return a * 0.7 + b


def sfx_hurt():
    d = 0.26
    n = lowpass(noise(int(SR * d)), 1400) * 0.5
    body = sweep(d, 130, 90) * 0.5
    return (n + body) * env(d, 0.002, 0.06)


def sfx_wave():
    d = 0.62
    t = t_axis(d)
    low = sweep(d, 220, 210, "saw") * 0.35
    high = sweep(d, 330, 320, "saw") * 0.25
    return (low + high) * np.exp(-t / 0.2) * env(d, 0.01, 0.25)


def sfx_reveal():
    d = 0.22
    t = t_axis(d)
    a = np.sin(2 * np.pi * 1180 * t) * np.exp(-t / 0.05)
    b = np.sin(2 * np.pi * 1770 * t) * np.exp(-np.clip(t - 0.04, 0, None) / 0.07) * 0.6
    return a * 0.6 + b


def sfx_scan_tick():
    d = 0.05
    n = noise(int(SR * d))
    return lowpass(n, 3500) * np.exp(-t_axis(d) / 0.008)


def sfx_heartbeat():
    d = 0.5
    t = t_axis(d)
    beat1 = np.sin(2 * np.pi * 62 * t) * np.exp(-t / 0.05)
    t2 = np.clip(t - 0.2, 0, None)
    beat2 = np.sin(2 * np.pi * 55 * t2) * np.exp(-t2 / 0.05) * 0.8
    return beat1 + beat2


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    save("sfx_shot.wav", sfx_shot())
    save("sfx_knife.wav", sfx_knife())
    save("sfx_hit.wav", sfx_hit())
    save("sfx_kill.wav", sfx_kill())
    save("sfx_repair.wav", sfx_repair())
    save("sfx_buy.wav", sfx_buy())
    save("sfx_loot.wav", sfx_loot())
    save("sfx_breach.wav", sfx_breach())
    save("sfx_crystal.wav", sfx_crystal())
    save("sfx_hurt.wav", sfx_hurt())
    save("sfx_wave.wav", sfx_wave())
    save("sfx_reveal.wav", sfx_reveal())
    save("sfx_scan_tick.wav", sfx_scan_tick())
    save("sfx_heartbeat.wav", sfx_heartbeat())


if __name__ == "__main__":
    main()