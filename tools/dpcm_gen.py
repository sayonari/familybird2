#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DPCM打楽器サンプルを合成して .dmc (1-bit delta) に変換する．
SMB3/カービィ風の打楽器: キック，タム(高/低; SMB3ティンバレス風)，スネア
出力: build/dpcm.bin (連結・64byte境界整列) と build/dpcm_meta.py (メタ情報)
"""
import math, random, struct

RATE = 33143.9  # DMC rate $F (NTSC最高)

def synth_kick():
    dur = 0.09
    n = int(RATE*dur)
    out = []
    f0, f1 = 160.0, 45.0
    ph = 0.0
    for i in range(n):
        t = i/n
        f = f0*(f1/f0)**(t**0.5)
        ph += 2*math.pi*f/RATE
        env = math.exp(-4.5*t)
        s = math.sin(ph)*env
        if i < int(0.004*RATE):  # クリックトランジェント
            s += (random.random()*2-1)*0.5*(1-i/(0.004*RATE))
        out.append(s)
    return out

def synth_tom(fs, fe, dur=0.11, noise_amt=0.35):
    """SMB3ティンバレス風: ピッチ下降サイン + 短いノイズアタック"""
    n = int(RATE*dur)
    out = []
    ph = 0.0
    for i in range(n):
        t = i/n
        f = fs*(fe/fs)**t
        ph += 2*math.pi*f/RATE
        env = math.exp(-3.8*t)
        s = math.sin(ph)*env
        s += 0.3*math.sin(2*ph)*env*env   # 倍音で皮っぽさ
        if i < int(0.006*RATE):
            s += (random.random()*2-1)*noise_amt*(1-i/(0.006*RATE))
        out.append(s)
    return out

def synth_snare():
    dur = 0.08
    n = int(RATE*dur)
    out = []
    ph = 0.0
    lp = 0.0
    for i in range(n):
        t = i/n
        ph += 2*math.pi*185.0/RATE
        body = math.sin(ph)*math.exp(-9*t)*0.5
        r = random.random()*2-1
        lp = lp*0.55 + r*0.45
        noise = lp*math.exp(-5.5*t)*0.95
        out.append(body+noise)
    return out

def to_dpcm(samples, gain=0.9):
    """PCM(float -1..1) -> DPCM 1bit delta. counterは0-127, delta±2"""
    # 正規化
    peak = max(abs(s) for s in samples) or 1.0
    scaled = [s/peak*63*gain+64 for s in samples]
    bits = []
    c = 64
    for s in scaled:
        if s >= c and c <= 125:
            bits.append(1); c += 2
        elif c >= 2:
            bits.append(0); c -= 2
        else:
            bits.append(1); c += 2
    # 長さを (n*16+1) バイトに整形
    nbytes = len(bits)//8
    nbytes = ((nbytes-1)//16)*16+1 if nbytes>=1 else 1
    bits = bits[:nbytes*8]
    data = bytearray()
    for i in range(0, len(bits), 8):
        b = 0
        for j in range(8):
            b |= bits[i+j] << j   # DMCはLSBファースト
        data.append(b)
    return bytes(data)

def main():
    random.seed(20140428)
    samples = {
        'kick':   to_dpcm(synth_kick()),
        'tom_hi': to_dpcm(synth_tom(310, 175)),
        'tom_lo': to_dpcm(synth_tom(215, 120, dur=0.13)),
        'snare':  to_dpcm(synth_snare()),
    }
    blob = bytearray()
    meta = {}
    for name, data in samples.items():
        # 64バイト境界に整列
        while len(blob) % 64 != 0:
            blob.append(0x55)  # 無音パディング(交互ビットでDCキープ)
        meta[name] = (len(blob), len(data))
        blob += data
    open('build/dpcm.bin','wb').write(blob)
    with open('build/dpcm_meta.py','w') as f:
        f.write("# offset,length (bytes) within dpcm.bin\n")
        f.write("DPCM_META = %r\n" % (meta,))
        f.write("DPCM_TOTAL = %d\n" % len(blob))
    for k,(o,l) in meta.items():
        print(f"{k}: offset={o} len={l} ({l/RATE*8*1000:.0f}ms)")
    print("total:", len(blob), "bytes")

if __name__ == "__main__":
    main()
