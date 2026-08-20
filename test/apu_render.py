#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""APUレジスタログ → WAV レンダラ (パルスx2/三角波/ノイズ/DPCM)"""
import sys, os, struct, math
sys.path.insert(0, os.path.dirname(__file__))
from emu import NES, A_, ST, SEL

SR = 44100
CPU = 1789772.7

NOISE_PERIODS = [4,8,16,32,64,96,128,160,202,254,380,508,762,1016,2034,4068]
DMC_RATES = [428,380,340,320,286,254,226,214,190,160,142,128,106,84,72,54]

class APURender:
    def __init__(self, dpcm_rom):
        self.dpcm_rom = dpcm_rom  # $C000からの16KB
        self.regs = bytearray(0x18)
        self.tri_on = False
        self.dmc = None  # (samplebytes, rate, pos_bit, counter)
        self.dmc_counter = 64
        self.noise_lfsr = 1
        self.p_phase = [0.0, 0.0]
        self.t_phase = 0.0
        self.n_acc = 0.0
        self.dmc_acc = 0.0

    def write(self, a, v):
        r = a - 0x4000
        if 0 <= r < 0x18: self.regs[r] = v
        if a == 0x4008:
            self.tri_on = (v & 0x7F) > 0 or (v & 0x80) > 0
        if a == 0x400B:
            if self.regs[8] == 0 and v == 0:
                self.tri_on = False
        if a == 0x4015:
            if v & 0x10:
                addr = 0xC000 + self.regs[0x12]*64
                length = self.regs[0x13]*16+1
                data = self.dpcm_rom[addr-0xC000:addr-0xC000+length]
                self.dmc = [data, DMC_RATES[self.regs[0x10]&0x0F], 0]
            else:
                self.dmc = None

    def sample(self, n):
        """nサンプル生成"""
        out = []
        DUTY = {0:0.125, 1:0.25, 2:0.5, 3:0.75}
        for _ in range(n):
            s = 0.0
            # pulses
            for ch in range(2):
                r0 = self.regs[ch*4]
                p = self.regs[ch*4+2] | ((self.regs[ch*4+3]&7)<<8)
                vol = r0 & 0x0F
                if vol and p >= 8:
                    f = CPU/(16*(p+1))
                    self.p_phase[ch] = (self.p_phase[ch] + f/SR) % 1.0
                    duty = DUTY[(r0>>6)&3]
                    s += (0.24*vol/15) * (1.0 if self.p_phase[ch] < duty else -1.0)
            # triangle
            p = self.regs[0x0A] | ((self.regs[0x0B]&7)<<8)
            if self.tri_on and p >= 2:
                f = CPU/(32*(p+1))
                self.t_phase = (self.t_phase + f/SR) % 1.0
                tri = 4*abs(self.t_phase-0.5)-1
                s += 0.30 * tri
            # noise
            r0 = self.regs[0x0C]
            vol = r0 & 0x0F
            if vol:
                per = NOISE_PERIODS[self.regs[0x0E]&0x0F]
                f = CPU/per
                self.n_acc += f/SR
                while self.n_acc >= 1:
                    self.n_acc -= 1
                    bit = 6 if (self.regs[0x0E] & 0x80) else 1
                    fb = (self.noise_lfsr ^ (self.noise_lfsr >> bit)) & 1
                    self.noise_lfsr = (self.noise_lfsr >> 1) | (fb << 14)
                s += (0.17*vol/15) * (1.0 if self.noise_lfsr & 1 else -1.0)
            # DPCM
            if self.dmc:
                data, rate, posbit = self.dmc
                f = CPU/rate
                self.dmc_acc += f/SR
                while self.dmc_acc >= 1 and self.dmc:
                    self.dmc_acc -= 1
                    bytei, biti = posbit >> 3, posbit & 7
                    if bytei >= len(data):
                        self.dmc = None
                        break
                    b = (data[bytei] >> biti) & 1
                    if b and self.dmc_counter <= 125: self.dmc_counter += 2
                    elif not b and self.dmc_counter >= 2: self.dmc_counter -= 2
                    posbit += 1
                    if self.dmc: self.dmc[2] = posbit
            s += 0.45 * (self.dmc_counter-64)/64
            out.append(s)
        return out

def render_log(log, dpcm_rom, path, frames):
    ap = APURender(dpcm_rom)
    byframe = {}
    f0 = log[0][0] if log else 0
    for f,a,v in log:
        byframe.setdefault(f-f0, []).append((a,v))
    samples = []
    spf = SR/60.0
    acc = 0.0
    for fr in range(frames):
        for a,v in byframe.get(fr, []):
            ap.write(a,v)
        acc += spf
        n = int(acc); acc -= n
        samples.extend(ap.sample(n))
    peak = max(1e-6, max(abs(x) for x in samples))
    g = 0.9/peak if peak > 0.9 else 1.0
    pcm = b''.join(struct.pack('<h', int(max(-1,min(1,x*g))*32767)) for x in samples)
    with open(path,'wb') as f:
        f.write(b'RIFF'+struct.pack('<I',36+len(pcm))+b'WAVEfmt '+struct.pack('<IHHIIHH',16,1,1,SR,SR*2,2,16)+b'data'+struct.pack('<I',len(pcm)))
        f.write(pcm)
    print(f"{path}: {len(samples)/SR:.1f}s")

nes = NES('build/FamilyBird2.nes')
dpcm_rom = nes.prg[0x4000:0x8000]  # $C000-$FFFF

# タイトルBGM
for _ in range(35): nes.run_frame(0)
nes.run_frame(ST)
for _ in range(5): nes.run_frame(0)
nes.apulog.clear()
for _ in range(900): nes.run_frame(0)
render_log(nes.apulog, dpcm_rom, 'build/bgm_title.wav', 900)

# ステージBGM (プレイなし: WAIT状態で音楽だけ)
nes.run_frame(ST)
for _ in range(5): nes.run_frame(0)
nes.apulog.clear()
for _ in range(1560): nes.run_frame(0)
render_log(nes.apulog, dpcm_rom, 'build/bgm_stage.wav', 1560)

# ゲームオーバージングル
nes.run_frame(A_)
for i in range(600):
    nes.run_frame(0)
    if nes.ram[0x0E] == 3: break
nes.apulog.clear()
for _ in range(360): nes.run_frame(0)
render_log(nes.apulog, dpcm_rom, 'build/bgm_gameover.wav', 360)

# スタッフロール
nes.run_frame(ST)
for _ in range(35): nes.run_frame(0)
nes.run_frame(SEL)
for _ in range(3): nes.run_frame(0)
nes.run_frame(ST)
for _ in range(5): nes.run_frame(0)
nes.apulog.clear()
for _ in range(900): nes.run_frame(0)
render_log(nes.apulog, dpcm_rom, 'build/bgm_staffroll.wav', 900)
print("done")
