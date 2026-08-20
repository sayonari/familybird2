#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""土管描画の整合性検証: 高速スクロール+移動土管で長時間回し,
ネームテーブル上の4列が常に同一ゲートか確認する"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from emu import NES, A_, ST

GAP_ROWS = 9
TILE_SKY = 0xEC

nes = NES('build/FamilyBird2.nes')
def zp(a): return nes.ram[a]
for _ in range(35): nes.run_frame(0)
nes.run_frame(ST)
for _ in range(35): nes.run_frame(0)
nes.run_frame(ST)
for _ in range(10): nes.run_frame(0)
nes.run_frame(A_)

# スコア75: 速度1.5 + 移動土管
for d,v in enumerate([5,7,0,0,0,0]): nes.ram[0x1A+d]=v

def col_tiles(col):
    out=[]
    for r in range(26):
        a = (0x400 if col>=32 else 0) + r*32 + (col&31)
        out.append(nes.vram[nes.ntaddr(a)])
    return out

def expected(colj, gap):
    out=[]
    for r in range(26):
        if r == gap-2 or r == gap+GAP_ROWS: t=0x40+colj
        elif r == gap-1 or r == gap+GAP_ROWS+1: t=0x50+colj
        elif gap <= r < gap+GAP_ROWS: t=TILE_SKY
        else: t=0x60+colj
        out.append(t)
    return out

maxbuf=0; checks=0; errors=0; moves=0
prev_gaps=[0]*4
prev=0
for i in range(6000):
    nes.ram[0x37]=200  # 無敵維持
    birdy=zp(0x30)
    pad = A_ if (birdy>110 and zp(0x33)<0x80 and prev==0) else 0
    prev=pad
    nes.run_frame(pad)
    maxbuf=max(maxbuf, zp(0x41))
    for s2 in range(4):
        g = nes.ram[0x404+s2]
        if g != prev_gaps[s2] and nes.ram[0x408+s2]: moves+=1
        prev_gaps[s2]=g
    if i%37==0 and zp(0x41)==0:  # バッファ空のときだけ検査
        for s2 in range(4):
            if nes.ram[0x400+s2]!=1: continue
            if nes.ram[0x418+s2]!=1: continue   # RECYC完了のみ
            if nes.ram[0x41C+s2]!=0: continue   # 移動窓の残りなし
            gap = nes.ram[0x404+s2]
            for j in range(4):
                got = col_tiles(s2*16+j)
                exp = expected(j, gap)
                checks+=1
                if got != exp:
                    errors+=1
                    if errors<=3:
                        print(f"[{i}] slot{s2} col{j} gap={gap} 不一致!")
                        for r in range(26):
                            if got[r]!=exp[r]: print(f"   row{r}: got={got[r]:02X} exp={exp[r]:02X}")
    assert zp(0x19)==1, f"died at {i}"
print(f"6000フレーム: 列検査{checks}回 不一致{errors} 移動{moves}回 maxbuf={maxbuf}")
print("INTEGRITY OK" if errors==0 and moves>10 and maxbuf<90 else "PROBLEM")
