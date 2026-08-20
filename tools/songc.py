#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FamilyBird2 音楽コンパイラ
songs/*.mml (MML風テキスト) -> build/songs.asm (サウンドドライバ用データ)

チャンネル: sq1, sq2, tri, noi, dpc
MML: c d e f g a b (+/#/-), 長さ(1,2,4,8,16,32, 付点.), ^タイ, r休符,
     o<n>オクターブ, > < , l<n>デフォルト長, @<n>音色, q<n>ゲート(1-8,8=テヌート), | 小節線(無視)
ノイズch: h=ハイハット閉 H=開 s=スネア b=ベードラ(noise) （長さ付与可）
DPCMch:  k=キック t=タム高 T=タム低 s=スネア
ドライバopcode:
  $00-$7C nn dd : ノートオン(音程idx, c1=0) + 持続フレーム
  $80 dd : 休符   $81 ii : 音色   $82 ll hh : ジャンプ(ループ)   $83 : 停止
"""
import sys, os, re, glob

NOTE_SEMI = {'c':0,'d':2,'e':4,'f':5,'g':7,'a':9,'b':11}

# ノイズドラム定義: name -> (period|mode<<7?, instrument番号)  周期は0-15
NOISE_DRUMS = {
    'h': (0x0E, 'nz_hat'),    # closed hat: 高周波短
    'H': (0x0D, 'nz_ohat'),   # open hat
    's': (0x07, 'nz_snare'),  # snare
    'b': (0x0B, 'nz_kick'),   # noise kick
}
DPCM_DRUMS = {'k':0, 't':1, 'T':2, 's':3}

# 音色定義 (duty, エンベロープ)  $FF=最後の値を保持
# (名前, duty, ビブラート深さ0-2, エンベロープ)
INSTRUMENTS = [
    ('lead',   0b10, 0, [13,12,11,10,10,9,9,8,8,8,7,7,7,6,6,6]),   # メインリード
    ('lead2',  0b01, 0, [10,9,8,8,7,7,7,6,6,6,5,5,5]),             # サブ/ハモリ
    ('pluck',  0b00, 0, [12,9,6,4,3,2,1,0]),                       # 短いプラック
    ('bass',   0b10, 0, [11,10,9,8,7,6,5,4,3,2,1,0]),              # パルスベース用
    ('tri',    0b00, 0, [15]),                                     # 三角波(音量無効)
    ('nz_hat', 0b00, 0, [7,4,2,0]),                                # ハイハット閉
    ('nz_ohat',0b00, 0, [7,5,4,3,2,2,1,1,0]),                      # ハイハット開
    ('nz_snare',0b00,0, [11,9,6,4,2,1,0]),                         # スネア
    ('nz_kick',0b00, 0, [10,6,3,1,0]),                             # ノイズキック
    ('arp',    0b01, 0, [12,11,10,9,8,7,6,5,4,3,2,1,0]),           # アルペジオ/伴奏
    ('softlead',0b10,1, [8,8,9,9,10,10,10,9,9,8,8,7,7,6,6,5]),     # ゆったりリード(軽vib)
    ('leadv',  0b10, 2, [13,13,12,12,11,11,11,10,10,10,10,10,9,9,9,9]), # 熱血リード(強vib)
    ('echo',   0b10, 0, [6,5,5,4,4,3,3,3]),                        # 疑似エコー(小音量)
    ('stab',   0b01, 0, [13,11,8,5,3,1,0]),                        # コードスタブ
    ('run',    0b10, 0, [11,10,9,8,8,7,7,6]),                      # 16分ラン用
]
INST_IDX = {name:i for i,(name,_,_,_) in enumerate(INSTRUMENTS)}

def note_table():
    """NTSC パルス/三角波用周期テーブル c1=idx0 .. b7=idx83"""
    import math
    CPU = 1789772.7
    out = []
    for idx in range(84):
        # c1 = MIDI 24
        midi = idx + 24
        f = 440.0 * 2 ** ((midi-69)/12)
        p = round(CPU/(16*f)) - 1
        p = max(0, min(0x7FF, p))
        out.append(p)
    return out

class MMLError(Exception): pass

def parse_channel(text, ch_kind, speed, songname, chname):
    """MML文字列 -> イベントリスト"""
    out = bytearray()
    i = 0
    octave = 4
    deflen = 8
    text = re.sub(r'#.*', '', text)
    pending = None  # (kind, value, frames) kind: 'note'/'rest'
    def flush():
        nonlocal pending
        if pending is None: return
        kind, val, fr = pending
        while fr > 255:
            emit(kind, val, 255)  # 分割(まれ)
            fr -= 255
        emit(kind, val, fr)
        pending = None
    def emit(kind, val, fr):
        if kind == 'note':
            out.append(val); out.append(fr)
        else:
            out.append(0x80); out.append(fr)
    def getlen(default_ok=True):
        nonlocal i
        m = re.match(r'(\d+)(\.*)', text[i:])
        if m and m.group(1):
            L = int(m.group(1)); dots = len(m.group(2))
            i += m.end()
        else:
            if not default_ok: raise MMLError("length expected")
            L = deflen; dots = 0
        # フレーム数: speed = 16分音符のフレーム数
        fr = speed * 16 // L
        add = fr
        for _ in range(dots):
            add //= 2; fr += add
        if fr < 1: raise MMLError(f"note too short: L{L}")
        return fr
    while i < len(text):
        c = text[i]
        if c in ' \t\n\r|': i += 1; continue
        if ch_kind == 'noi' and c in NOISE_DRUMS:
            i += 1
            fr = getlen()
            flush()
            period, instname = NOISE_DRUMS[c]
            out.append(0x81); out.append(INST_IDX[instname])
            pending = ('note', period, fr)
            continue
        if ch_kind == 'dpc' and c in DPCM_DRUMS:
            i += 1
            fr = getlen()
            flush()
            pending = ('note', DPCM_DRUMS[c], fr)
            continue
        if c in 'cdefgab' and ch_kind in ('sq1','sq2','tri'):
            i += 1
            semi = NOTE_SEMI[c]
            while i < len(text) and text[i] in '+#-':
                semi += 1 if text[i] in '+#' else -1
                i += 1
            fr = getlen()
            idx = (octave-1)*12 + semi
            if not (0 <= idx <= 0x7C):
                raise MMLError(f"{songname}/{chname}: 音域外 o{octave}{c}")
            flush()
            pending = ('note', idx, fr)
            continue
        if c == 'r':
            i += 1
            fr = getlen()
            flush()
            pending = ('rest', 0, fr)
            continue
        if c == '^':
            i += 1
            fr = getlen()
            if pending is None: raise MMLError("tie without note")
            pending = (pending[0], pending[1], pending[2]+fr)
            continue
        if c == 'o':
            i += 1
            m = re.match(r'\d', text[i:])
            if not m: raise MMLError("o needs digit")
            octave = int(m.group(0)); i += 1
            continue
        if c == '>': octave += 1; i += 1; continue
        if c == '<': octave -= 1; i += 1; continue
        if c == 'l':
            i += 1
            m = re.match(r'\d+', text[i:])
            deflen = int(m.group(0)); i += m.end()
            continue
        if c == '@':
            i += 1
            m = re.match(r'\w+', text[i:])
            name = m.group(0); i += m.end()
            if name not in INST_IDX: raise MMLError(f"unknown inst {name}")
            flush()
            out.append(0x81); out.append(INST_IDX[name])
            continue
        raise MMLError(f"{songname}/{chname}: 解釈不能文字 '{c}' 位置{i}")
    flush()
    return out

def compile_song(path):
    name = None; speed = 7; loop = True
    chans = {k: '' for k in ('sq1','sq2','tri','noi','dpc')}
    for line in open(path, encoding='utf-8'):
        line = line.rstrip()
        if re.match(r'\s*#', line) or not line.strip(): continue
        m = re.match(r'song\s+(\w+)(\s+noloop)?', line)
        if m:
            name = m.group(1); loop = not m.group(2); continue
        m = re.match(r'speed\s+(\d+)', line)
        if m: speed = int(m.group(1)); continue
        m = re.match(r'@(sq1|sq2|tri|noi|dpc)\s*:\s*(.*)', line)
        if m:
            chans[m.group(1)] += ' ' + m.group(2); continue
        raise MMLError(f"{path}: 解釈不能行: {line}")
    streams = {}
    for ch, txt in chans.items():
        if not txt.strip(): continue
        streams[ch] = parse_channel(txt, ch, speed, name, ch)
    return name, loop, streams

def check_lengths(name, loop, streams):
    """ループ曲は全chの総フレーム数が一致しないと徐々にズレるのでエラーにする"""
    if not loop or len(streams) < 2:
        return
    lens = {}
    for ch, data in streams.items():
        t = 0; i = 0
        while i < len(data):
            b = data[i]
            if b <= 0x80: t += data[i+1]; i += 2
            elif b == 0x81: i += 2
            else: i += 1
        lens[ch] = t
    if len(set(lens.values())) != 1:
        raise MMLError(f"{name}: チャンネル長が不一致 {lens}")

BANK2_BUDGET = 7800   # 固定テーブル+ストリームでバンク2に収める上限(バイト)

def main():
    files = sorted(glob.glob('songs/*.mml'))
    songs = []
    for f in files:
        song = compile_song(f)
        check_lengths(*song)
        songs.append(song)
    # 曲順: ファイル名の数字プレフィクス順
    lines = []
    A = lines.append
    A('; ===== 自動生成: songc.py =====')
    A('note_table_lo:')
    nt = note_table()
    for i in range(0, 84, 12):
        A('\t.db ' + ','.join('$%02X' % (p & 0xFF) for p in nt[i:i+12]))
    A('note_table_hi:')
    for i in range(0, 84, 12):
        A('\t.db ' + ','.join('$%02X' % (p >> 8) for p in nt[i:i+12]))
    A('; --- instruments ---')
    A('inst_duty:')
    A('\t.db ' + ','.join('$%02X' % (d << 6) for _, d, _, _ in INSTRUMENTS))
    A('inst_vib:')
    A('\t.db ' + ','.join('$%02X' % v for _, _, v, _ in INSTRUMENTS))
    A('inst_env_lo:')
    for n, _, _, _ in INSTRUMENTS:
        A(f'\t.db low(env_{n})')
    A('inst_env_hi:')
    for n, _, _, _ in INSTRUMENTS:
        A(f'\t.db high(env_{n})')
    for n, _, _, env in INSTRUMENTS:
        A(f'env_{n}:\t.db ' + ','.join('$%02X' % v for v in env) + ',$FF')
    A('; --- songs ---')
    A('song_table:')
    for name, loop, streams in songs:
        for ch in ('sq1','sq2','tri','noi','dpc'):
            if ch in streams:
                A(f'\t.dw sng_{name}_{ch}')
            else:
                A('\t.dw $0000')
    # ---- バンク分割: 固定テーブルは songs.asm(バンク2), 溢れた曲は songs2.asm(バンク3) ----
    # ここまでの lines は「テーブル部+song_table」まで(ストリームは未出力)なので,
    # ストリームをサイズ集計しながら振り分ける
    fixed_size = 168 + len(INSTRUMENTS)*5 + sum(len(e)+1 for _,_,_,e in INSTRUMENTS) + len(songs)*10
    linesB = []
    B = linesB.append
    B('; ===== 自動生成: songc.py (バンク3側の楽曲ストリーム) =====')
    used = fixed_size
    for name, loop, streams in songs:
        size = sum(len(d) + (3 if loop else 1) for d in streams.values())
        target = lines if used + size <= BANK2_BUDGET else linesB
        if target is lines:
            used += size
        AA = target.append
        for ch, data in streams.items():
            label = f'sng_{name}_{ch}'
            body = bytearray(data)
            AA(f'{label}:')
            for i in range(0, len(body), 16):
                AA('\t.db ' + ','.join('$%02X' % b for b in body[i:i+16]))
            if loop:
                AA('\t.db $82')
                AA(f'\t.dw {label}')
            else:
                AA('\t.db $83')
    open('build/songs.asm','w').write('\n'.join(lines) + '\n')
    open('build/songs2.asm','w').write('\n'.join(linesB) + '\n')
    total = sum(len(d) for _,_,s in songs for d in s.values())
    print(f"songs: {[n for n,_,_ in songs]}  data={total}B  bank2={used}B -> songs.asm / songs2.asm")

if __name__ == '__main__':
    main()
