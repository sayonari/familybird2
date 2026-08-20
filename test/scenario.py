#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""起動→タイトル→ゲーム→ゲームオーバーの通しテスト"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from emu import NES, render, A_, B_, SEL, ST

OUT = os.environ.get('SHOTDIR', 'build')

nes = NES('build/FamilyBird2.nes')

def frames(n, pad=0):
    for _ in range(n):
        nes.run_frame(pad)

def zp(a): return nes.ram[a]

print("== boot ==")
frames(30)
print(f"SCENE={zp(0x0E)} PPU_ON={zp(0x10)} mask={nes.ppumask:02X} ctrl={nes.ppuctrl:02X}")
render(nes, f'{OUT}/shot_logo.png')

print("== to title (START) ==")
frames(1, ST); frames(30)
print(f"SCENE={zp(0x0E)} INITED={zp(0x3E)}")
render(nes, f'{OUT}/shot_title.png')

print("== char change (B) ==")
frames(1, B_); frames(10)
print(f"CHARA={zp(0x36)}")

print("== start game ==")
frames(1, ST); frames(10)
print(f"SCENE={zp(0x0E)} GAME_ST={zp(0x19)} birdY={zp(0x30)}")
render(nes, f'{OUT}/shot_game_wait.png')

print("== first flap ==")
frames(1, A_); frames(5)
print(f"GAME_ST={zp(0x19)} birdY={zp(0x30)} velH={zp(0x33):02X}")

print("== play: flap periodically ==")
# だいたい高度維持: 22フレームごとにA
for i in range(600):
    pad = A_ if i % 22 == 0 else 0
    nes.run_frame(pad)
    if zp(0x19) != 1:
        print(f"  died at frame {i}, birdY={zp(0x30)}")
        break
print(f"GAME_ST={zp(0x19)} scroll={zp(0x16)*256+zp(0x15)} score={''.join(str(zp(0x1F-i)) for i in range(6))}")
print(f"pipes ACT={[nes.ram[0x400+i] for i in range(4)]} GAP={[nes.ram[0x404+i] for i in range(4)]}")
print(f"items ACT={[nes.ram[0x420+i] for i in range(2)]} TYPE={[nes.ram[0x422+i] for i in range(2)]}")
render(nes, f'{OUT}/shot_game_play.png')
print(f"max vram writes/frame (rendering on): {nes.max_vram_writes}")

print("== stop flapping -> die ==")
for i in range(300):
    nes.run_frame(0)
    if zp(0x0E) == 3:
        print(f"  gameover at +{i}")
        break
print(f"SCENE={zp(0x0E)} GAME_ST={zp(0x19)}")
frames(30)
render(nes, f'{OUT}/shot_gameover.png')

print("== back to title ==")
frames(1, ST); frames(30)
print(f"SCENE={zp(0x0E)}")
render(nes, f'{OUT}/shot_title2.png')

print("== staff roll ==")
frames(1, SEL); frames(5)
frames(1, ST); frames(30)
print(f"SCENE={zp(0x0E)}")
render(nes, f'{OUT}/shot_staff.png')

# APUアクティビティ確認
from collections import Counter
c = Counter(a for f,a,v in nes.apulog)
print("APU write counts:", {f'{k:04X}': v for k,v in sorted(c.items())})
print("OK")
