#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""新要素の検証: ランダムBGM/パレット位相/加速/スター曲/ポーズ/メダル"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from emu import NES, render, A_, ST

def boot_to_game(extra_title_frames=0):
    nes = NES('build/FamilyBird2.nes')
    for _ in range(35): nes.run_frame(0)
    nes.run_frame(ST)
    for _ in range(35 + extra_title_frames): nes.run_frame(0)
    nes.run_frame(ST)
    for _ in range(10): nes.run_frame(0)
    nes.run_frame(A_)
    return nes

def zp(nes,a): return nes.ram[a]

# --- 1. ランダムBGM選曲 ---
songs = set()
for k in range(6):
    nes = boot_to_game(extra_title_frames=k*7)
    songs.add(zp(nes,0x3F))
print("選曲されたBGM:", sorted(songs), "(2=rock 5=idol 6=cute)")
assert songs <= {2,5,6}

# --- 2. パレット位相 + 加速 ---
nes = boot_to_game()
def autopilot(nes, frames, star_poke=False):
    prev = 0
    events = []
    for i in range(frames):
        scroll = zp(nes,0x16)*256+zp(nes,0x15)
        birdw = (scroll+72)&511
        best,bg = 10**9,8
        for s2 in range(4):
            if nes.ram[0x400+s2]==0: continue
            d=((s2*128+40)-birdw)&511
            if d<best and d<440: best,bg=d,nes.ram[0x404+s2]
        target=bg*8+24
        want = zp(nes,0x30)>target and zp(nes,0x33)<0x80
        pad = A_ if (want and prev==0) else 0
        prev=pad
        nes.run_frame(pad)
        if zp(nes,0x19)==2: return events, i
    return events, None

# スコア12まで進める(パレット確認): スコアを直接ポーク
for d,v in enumerate([2,1,0,0,0,0]): nes.ram[0x1A+d]=v  # score=12
autopilot(nes, 5)
print("score12: PALPHASE=",zp(nes,0x45)," sky=",hex(nes.ram[0x4C0]))
assert zp(nes,0x45)==1 and nes.ram[0x4C0]==0x36, "夕焼けになるはず"
for d,v in enumerate([5,2,0,0,0,0]): nes.ram[0x1A+d]=v  # score=25
autopilot(nes, 5)
print("score25: PALPHASE=",zp(nes,0x45)," sky=",hex(nes.ram[0x4C0]))
assert zp(nes,0x45)==2 and nes.ram[0x4C0]==0x02, "夜になるはず"
render(nes,'build/shot_night.png')
for d,v in enumerate([2,3,0,0,0,0]): nes.ram[0x1A+d]=v  # score=32
autopilot(nes, 5)
print("score32: SPEED_ADD=",hex(zp(nes,0x44)))
assert zp(nes,0x44)==0x40
for d,v in enumerate([5,7,0,0,0,0]): nes.ram[0x1A+d]=v  # score=75
autopilot(nes, 5)
assert zp(nes,0x44)==0x80
print("加速OK")

# --- 3. スター曲切り替え ---
ptr_before = bytes(nes.ram[0x50:0x5A])
# アイテムを強制スター化して取得させる
nes.ram[0x420]=1; nes.ram[0x422]=1; nes.ram[0x42C]=1
scroll = zp(nes,0x16)*256+zp(nes,0x15)
ix = (scroll+80)&511
nes.ram[0x424]=ix&0xFF; nes.ram[0x426]=ix>>8
nes.ram[0x428]=zp(nes,0x30)
for _ in range(40):
    nes.run_frame(0)
    if zp(nes,0x37): break
assert zp(nes,0x37)>0, "スター取得失敗"
ptr_star = bytes(nes.ram[0x50:0x5A])
assert ptr_star != ptr_before, "スター曲に切り替わっていない"
print("スター取得→専用曲OK (timer=",zp(nes,0x37),")")
# タイマー切れ→復帰
nes.ram[0x37]=2
autopilot(nes,6)
ptr_after = bytes(nes.ram[0x50:0x5A])
assert ptr_after != ptr_star, "BGM復帰していない"
print("スター終了→BGM復帰OK")

# --- 4. ポーズ ---
sc_before = zp(nes,0x15)
nes.run_frame(ST); nes.run_frame(0)
assert zp(nes,0x46)==1, "ポーズになっていない"
p1 = zp(nes,0x15)
for _ in range(30): nes.run_frame(0)
assert zp(nes,0x15)==p1, "ポーズ中にスクロールしている"
nes.run_frame(ST); nes.run_frame(0); nes.run_frame(0)
assert zp(nes,0x46)==0 and zp(nes,0x15)!=p1, "ポーズ解除失敗"
print("ポーズOK")

# --- 5. ゲームオーバー: メダル + NEW RECORD ---
for _ in range(300):
    nes.run_frame(0)
    if zp(nes,0x0E)==3: break
assert zp(nes,0x0E)==3
print("NEWREC=",zp(nes,0x47))
for _ in range(20): nes.run_frame(0)  # メダル/レコード描画フレームを通過
render(nes,'build/shot_medal.png')
print("ALL FEATURES OK")
