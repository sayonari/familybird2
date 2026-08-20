#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""自動操縦で長時間プレイし，得点/アイテム/移動土管/スターを検証"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from emu import NES, render, A_, ST, B_

nes = NES('build/FamilyBird2.nes')
def zp(a): return nes.ram[a]
def frames(n, pad=0):
    for _ in range(n): nes.run_frame(pad)

# タイトルまで
frames(35); nes.run_frame(ST); frames(35)
# ゲーム開始
nes.run_frame(ST); frames(10)
nes.run_frame(A_)  # 最初の羽ばたき
assert zp(0x19) == 1, "GS_RUN expected"

def upcoming_gap():
    scroll = zp(0x16)*256 + zp(0x15)
    birdw = (scroll + 72) & 511
    best, bestgap = 10**9, 8
    for s in range(4):
        if nes.ram[0x400+s] == 0: continue
        px = s*128 + 40          # 右端+8まで対象(通過完了まで)
        d = (px - birdw) & 511
        if d < best and d < 440:
            best, bestgap = d, nes.ram[0x404+s]
    return bestgap

score_events = []
item_events = []
prev_score = 0
prev_items = [0,0]
star_seen = False
moving_seen = False
died = None

prev_pad = 0
for i in range(4000):
    gap = upcoming_gap()
    target = gap*8 + 24
    birdy = zp(0x30)
    velh = zp(0x33)
    falling = velh < 0x80
    want = (birdy > target and falling)
    pad = A_ if (want and prev_pad == 0) else 0
    prev_pad = pad
    nes.run_frame(pad)
    sc = sum(nes.ram[0x1A+d]*10**d for d in range(6))
    if sc != prev_score:
        score_events.append((i, prev_score, sc))
        prev_score = sc
    for j in range(2):
        act = nes.ram[0x420+j]
        if act != prev_items[j]:
            item_events.append((i, j, act, nes.ram[0x422+j], nes.ram[0x428+j]))
            prev_items[j] = act
    # アイテムを鳥の高さに引き寄せて取得テスト (フレーム800以降, 接近中のみ)
    if i > 800:
        for j in range(2):
            if nes.ram[0x420+j]:
                ix = nes.ram[0x424+j] + nes.ram[0x426+j]*256
                scroll = zp(0x16)*256 + zp(0x15)
                sx = (ix - scroll) & 511
                if 80 < sx < 200:
                    nes.ram[0x428+j] = zp(0x30)  # y座標を鳥に合わせる
    if zp(0x37) and not star_seen:
        star_seen = True
        print(f"[{i}] STAR taken! timer={zp(0x37)}")
        render(nes, 'build/shot_star.png')
    if any(nes.ram[0x408+s] for s in range(4)) and not moving_seen:
        moving_seen = True
        print(f"[{i}] moving pipe appeared (score={sc}) MOV={[nes.ram[0x408+s] for s in range(4)]}")
    if zp(0x19) == 2:
        died = i
        print(f"[{i}] died. score={sc} birdY={birdy} gap={gap}")
        render(nes, 'build/shot_died.png')
        break

print("score events:", score_events[:12], "..." if len(score_events)>12 else "")
print("item events:", item_events[:12])
print(f"final score={prev_score} star_seen={star_seen} moving_seen={moving_seen} died_at={died}")
print(f"max vram writes/frame: {nes.max_vram_writes}")
render(nes, 'build/shot_autopilot.png')

# DPCM発音回数
dpcm = sum(1 for f,a,v in nes.apulog if a == 0x4013)
print(f"DPCM triggers: {dpcm}")
