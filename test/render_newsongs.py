#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""新BGM (idol/cute/star) のWAVレンダリング"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
src = open(os.path.join(os.path.dirname(__file__), 'apu_render.py')).read().split("nes = NES(")[0]
exec(src)
from emu import NES, A_, ST

def boot_with_song(target):
    """選曲が deterministic なのでタイトル滞在フレーム数を変えて目的の曲を引く"""
    for extra in range(0, 40):
        nes = NES('build/FamilyBird2.nes')
        for _ in range(35): nes.run_frame(0)
        nes.run_frame(ST)
        for _ in range(35+extra): nes.run_frame(0)
        nes.run_frame(ST)
        for _ in range(10): nes.run_frame(0)
        if nes.ram[0x3F] == target:
            return nes
    raise SystemExit(f"song {target} not selected in 40 tries")

for target, name, frames in [(5,'idol',1560),(6,'cute',1560)]:
    nes = boot_with_song(target)
    nes.apulog.clear()
    for _ in range(frames): nes.run_frame(0)
    dpcm_rom = nes.prg[0x4000:0x8000]
    render_log(nes.apulog, dpcm_rom, f'build/bgm_{name}.wav', frames)

# スター曲: ゲーム中にスターを強制取得
nes = boot_with_song(2)
nes.run_frame(A_)
for _ in range(30): nes.run_frame(0)
nes.ram[0x420]=1; nes.ram[0x422]=1; nes.ram[0x42C]=1
scroll = nes.ram[0x16]*256+nes.ram[0x15]
ix = (scroll+80)&511
nes.ram[0x424]=ix&0xFF; nes.ram[0x426]=ix>>8
nes.ram[0x428]=nes.ram[0x30]
prev=0
for i in range(80):
    nes.ram[0x428]=nes.ram[0x30]      # アイテムYを鳥に追従
    birdy=nes.ram[0x30]
    pad = A_ if (birdy>110 and nes.ram[0x33]<0x80 and prev==0) else 0
    prev=pad
    nes.run_frame(pad)
    if nes.ram[0x37]: break
assert nes.ram[0x37] > 0
nes.apulog.clear()
prev=0
for i in range(600):
    nes.ram[0x37]=200            # 無敵維持
    birdy=nes.ram[0x30]
    pad = A_ if (birdy>110 and nes.ram[0x33]<0x80 and prev==0) else 0
    prev=pad
    nes.run_frame(pad)
dpcm_rom = nes.prg[0x4000:0x8000]
render_log(nes.apulog, dpcm_rom, 'build/bgm_star.wav', 600)
print("done")
