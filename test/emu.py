#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""FamilyBird2 検証用ヘッドレスNESエミュレータ (6502 + 最小PPU/APU)
命令数ベースの近似タイミング．ロジック検証・画面レンダリング用．
"""
import struct, zlib, sys

class NES:
    def __init__(self, rompath):
        d = open(rompath,'rb').read()
        assert d[:4] == b'NES\x1a'
        prg_banks, chr_banks = d[4], d[5]
        self.mirror_v = bool(d[6] & 1)
        off = 16
        self.prg = d[off:off+prg_banks*16384]
        off += prg_banks*16384
        self.chr = d[off:off+chr_banks*8192]
        self.ram = bytearray(0x800)
        self.vram = bytearray(0x1000)   # 2KB + predec mirror space
        self.pal = bytearray(32)
        self.oam = bytearray(256)
        # PPU state
        self.v = 0; self.w = 0; self.ppuctrl = 0; self.ppumask = 0
        self.vbl = False
        self.scroll_x = 0; self.scroll_y = 0
        self.readbuf = 0
        # APU log
        self.apulog = []
        self.apuregs = bytearray(0x18)
        self.frame = 0
        # controller
        self.pad_state = 0
        self.pad_shift = 0
        self.pad_strobe = 0
        # CPU
        self.A=0; self.X=0; self.Y=0; self.S=0xFD; self.P=0x24
        self.PC = self.r16(0xFFFC)
        self.vram_writes_this_frame = 0
        self.max_vram_writes = 0

    # ---------- memory ----------
    def ntaddr(self, a):
        a &= 0x0FFF
        table = a // 0x400
        off = a & 0x3FF
        if self.mirror_v: table &= 1
        else: table = (table >> 1) & 1
        return table*0x400 + off

    def read(self, a):
        a &= 0xFFFF
        if a < 0x2000: return self.ram[a & 0x7FF]
        if a < 0x4000:
            r = a & 7
            if r == 2:
                v = (0x80 if self.vbl else 0)
                self.vbl = False
                self.w = 0
                return v
            if r == 7:
                va = self.v & 0x3FFF
                if va >= 0x3F00:
                    v = self.pal[va & 0x1F]
                else:
                    v = self.readbuf
                    if va >= 0x2000: self.readbuf = self.vram[self.ntaddr(va)]
                    else: self.readbuf = self.chr[va]
                self.v = (self.v + (32 if self.ppuctrl&4 else 1)) & 0x7FFF
                return v
            return 0
        if a == 0x4016:
            v = (self.pad_shift & 1)
            self.pad_shift >>= 1
            self.pad_shift |= 0x80  # 読み尽くしたら1
            return v | 0x40
        if a == 0x4017: return 0x40
        if a < 0x4020: return 0
        if a >= 0x8000:
            return self.prg[(a - 0x8000) % len(self.prg)]
        return 0

    def write(self, a, val):
        a &= 0xFFFF; val &= 0xFF
        if a < 0x2000: self.ram[a & 0x7FF] = val; return
        if a < 0x4000:
            r = a & 7
            if r == 0: self.ppuctrl = val
            elif r == 1: self.ppumask = val
            elif r == 3: self.oamaddr = val
            elif r == 4: pass
            elif r == 5:
                if self.w == 0: self.scroll_x_t = val; self.w = 1
                else:
                    self.scroll_y = val; self.w = 0
                    self.scroll_x = self.scroll_x_t
            elif r == 6:
                if self.w == 0: self.v = (self.v & 0xFF) | ((val & 0x3F) << 8); self.w = 1
                else: self.v = (self.v & 0xFF00) | val; self.w = 0
            elif r == 7:
                va = self.v & 0x3FFF
                if va >= 0x3F00:
                    i = va & 0x1F
                    self.pal[i] = val
                    if i % 4 == 0: self.pal[i ^ 0x10] = val
                elif va >= 0x2000:
                    self.vram[self.ntaddr(va)] = val
                    if not self.rendering_off():
                        self.vram_writes_this_frame += 1
                self.v = (self.v + (32 if self.ppuctrl&4 else 1)) & 0x7FFF
            return
        if a == 0x4014:
            base = val << 8
            for i in range(256):
                self.oam[i] = self.read(base + i)
            return
        if a == 0x4016:
            if self.pad_strobe and not (val & 1):
                self.pad_shift = self.pad_state
            self.pad_strobe = val & 1
            if self.pad_strobe: self.pad_shift = self.pad_state
            return
        if 0x4000 <= a <= 0x4017:
            self.apuregs[a - 0x4000] = val
            self.apulog.append((self.frame, a, val))
            return

    def rendering_off(self):
        return (self.ppumask & 0x18) == 0

    def r16(self, a): return self.read(a) | (self.read(a+1) << 8)

    # ---------- CPU ----------
    def push(self, v): self.write(0x100 + self.S, v); self.S = (self.S - 1) & 0xFF
    def pop(self): self.S = (self.S + 1) & 0xFF; return self.read(0x100 + self.S)
    def setnz(self, v):
        v &= 0xFF
        self.P = (self.P & ~0x82) | (0x80 if v & 0x80 else 0) | (0x02 if v == 0 else 0)
        return v

    def nmi(self):
        self.push((self.PC >> 8) & 0xFF); self.push(self.PC & 0xFF)
        self.push(self.P & ~0x10)
        self.P |= 0x04
        self.PC = self.r16(0xFFFA)

    def step(self):
        op = self.read(self.PC); pc = self.PC; self.PC = (self.PC + 1) & 0xFFFF
        def imm():
            v = self.read(self.PC); self.PC = (self.PC+1)&0xFFFF; return v
        def zp(): return imm()
        def zpx(): return (imm() + self.X) & 0xFF
        def zpy(): return (imm() + self.Y) & 0xFF
        def ab():
            v = self.r16(self.PC); self.PC = (self.PC+2)&0xFFFF; return v
        def abx(): return (ab() + self.X) & 0xFFFF
        def aby(): return (ab() + self.Y) & 0xFFFF
        def izx():
            z = zpx(); return self.ram[z] | (self.ram[(z+1)&0xFF] << 8)
        def izy():
            z = imm(); return ((self.ram[z] | (self.ram[(z+1)&0xFF] << 8)) + self.Y) & 0xFFFF
        def br(cond):
            off = imm()
            if cond:
                if off >= 128: off -= 256
                self.PC = (self.PC + off) & 0xFFFF
        def adc(v):
            c = self.P & 1
            r = self.A + v + c
            self.P = (self.P & ~0x41) | (1 if r > 0xFF else 0)
            ov = (~(self.A ^ v) & (self.A ^ r)) & 0x80
            self.P = (self.P & ~0x40) | (0x40 if ov else 0)
            self.A = self.setnz(r)
        def sbc(v): adc(v ^ 0xFF)
        def cmp_(reg, v):
            r = reg - v
            self.P = (self.P & ~1) | (1 if r >= 0 else 0)
            self.setnz(r & 0xFF)
        def asl(v):
            self.P = (self.P & ~1) | (1 if v & 0x80 else 0)
            return self.setnz((v << 1) & 0xFF)
        def lsr(v):
            self.P = (self.P & ~1) | (v & 1)
            return self.setnz(v >> 1)
        def rol(v):
            c = self.P & 1
            self.P = (self.P & ~1) | (1 if v & 0x80 else 0)
            return self.setnz(((v << 1) | c) & 0xFF)
        def ror(v):
            c = self.P & 1
            self.P = (self.P & ~1) | (v & 1)
            return self.setnz((v >> 1) | (c << 7))
        def bit(v):
            self.P = (self.P & ~0xC2) | (v & 0xC0) | (0 if self.A & v else 2)

        o = op
        # 分岐/フロー
        if o == 0xEA: pass
        elif o == 0x4C: self.PC = ab()
        elif o == 0x6C:
            a = ab()
            lo = self.read(a); hi = self.read((a & 0xFF00) | ((a+1) & 0xFF))
            self.PC = lo | (hi << 8)
        elif o == 0x20:
            a = ab()
            r = (self.PC - 1) & 0xFFFF
            self.push(r >> 8); self.push(r & 0xFF)
            self.PC = a
        elif o == 0x60:
            lo = self.pop(); hi = self.pop()
            self.PC = ((hi << 8) | lo) + 1 & 0xFFFF
        elif o == 0x40:
            self.P = (self.pop() | 0x20) & ~0x10
            lo = self.pop(); hi = self.pop()
            self.PC = (hi << 8) | lo
        elif o == 0x00:
            self.PC = (self.PC + 1) & 0xFFFF
            self.push(self.PC >> 8); self.push(self.PC & 0xFF)
            self.push(self.P | 0x10); self.P |= 4
            self.PC = self.r16(0xFFFE)
        elif o == 0x10: br(not (self.P & 0x80))
        elif o == 0x30: br(self.P & 0x80)
        elif o == 0x50: br(not (self.P & 0x40))
        elif o == 0x70: br(self.P & 0x40)
        elif o == 0x90: br(not (self.P & 1))
        elif o == 0xB0: br(self.P & 1)
        elif o == 0xD0: br(not (self.P & 2))
        elif o == 0xF0: br(self.P & 2)
        # フラグ
        elif o == 0x18: self.P &= ~1
        elif o == 0x38: self.P |= 1
        elif o == 0x58: self.P &= ~4
        elif o == 0x78: self.P |= 4
        elif o == 0xB8: self.P &= ~0x40
        elif o == 0xD8: self.P &= ~8
        elif o == 0xF8: self.P |= 8
        # レジスタ転送
        elif o == 0xAA: self.X = self.setnz(self.A)
        elif o == 0x8A: self.A = self.setnz(self.X)
        elif o == 0xA8: self.Y = self.setnz(self.A)
        elif o == 0x98: self.A = self.setnz(self.Y)
        elif o == 0xBA: self.X = self.setnz(self.S)
        elif o == 0x9A: self.S = self.X
        elif o == 0xC8: self.Y = self.setnz(self.Y + 1)
        elif o == 0x88: self.Y = self.setnz(self.Y - 1)
        elif o == 0xE8: self.X = self.setnz(self.X + 1)
        elif o == 0xCA: self.X = self.setnz(self.X - 1)
        elif o == 0x48: self.push(self.A)
        elif o == 0x68: self.A = self.setnz(self.pop())
        elif o == 0x08: self.push(self.P | 0x30)
        elif o == 0x28: self.P = (self.pop() | 0x20) & ~0x10
        # LDA
        elif o == 0xA9: self.A = self.setnz(imm())
        elif o == 0xA5: self.A = self.setnz(self.read(zp()))
        elif o == 0xB5: self.A = self.setnz(self.read(zpx()))
        elif o == 0xAD: self.A = self.setnz(self.read(ab()))
        elif o == 0xBD: self.A = self.setnz(self.read(abx()))
        elif o == 0xB9: self.A = self.setnz(self.read(aby()))
        elif o == 0xA1: self.A = self.setnz(self.read(izx()))
        elif o == 0xB1: self.A = self.setnz(self.read(izy()))
        # LDX/LDY
        elif o == 0xA2: self.X = self.setnz(imm())
        elif o == 0xA6: self.X = self.setnz(self.read(zp()))
        elif o == 0xB6: self.X = self.setnz(self.read(zpy()))
        elif o == 0xAE: self.X = self.setnz(self.read(ab()))
        elif o == 0xBE: self.X = self.setnz(self.read(aby()))
        elif o == 0xA0: self.Y = self.setnz(imm())
        elif o == 0xA4: self.Y = self.setnz(self.read(zp()))
        elif o == 0xB4: self.Y = self.setnz(self.read(zpx()))
        elif o == 0xAC: self.Y = self.setnz(self.read(ab()))
        elif o == 0xBC: self.Y = self.setnz(self.read(abx()))
        # STA/STX/STY
        elif o == 0x85: self.write(zp(), self.A)
        elif o == 0x95: self.write(zpx(), self.A)
        elif o == 0x8D: self.write(ab(), self.A)
        elif o == 0x9D: self.write(abx(), self.A)
        elif o == 0x99: self.write(aby(), self.A)
        elif o == 0x81: self.write(izx(), self.A)
        elif o == 0x91: self.write(izy(), self.A)
        elif o == 0x86: self.write(zp(), self.X)
        elif o == 0x96: self.write(zpy(), self.X)
        elif o == 0x8E: self.write(ab(), self.X)
        elif o == 0x84: self.write(zp(), self.Y)
        elif o == 0x94: self.write(zpx(), self.Y)
        elif o == 0x8C: self.write(ab(), self.Y)
        # ADC/SBC
        elif o == 0x69: adc(imm())
        elif o == 0x65: adc(self.read(zp()))
        elif o == 0x75: adc(self.read(zpx()))
        elif o == 0x6D: adc(self.read(ab()))
        elif o == 0x7D: adc(self.read(abx()))
        elif o == 0x79: adc(self.read(aby()))
        elif o == 0x61: adc(self.read(izx()))
        elif o == 0x71: adc(self.read(izy()))
        elif o == 0xE9: sbc(imm())
        elif o == 0xE5: sbc(self.read(zp()))
        elif o == 0xF5: sbc(self.read(zpx()))
        elif o == 0xED: sbc(self.read(ab()))
        elif o == 0xFD: sbc(self.read(abx()))
        elif o == 0xF9: sbc(self.read(aby()))
        elif o == 0xE1: sbc(self.read(izx()))
        elif o == 0xF1: sbc(self.read(izy()))
        # 論理
        elif o == 0x29: self.A = self.setnz(self.A & imm())
        elif o == 0x25: self.A = self.setnz(self.A & self.read(zp()))
        elif o == 0x35: self.A = self.setnz(self.A & self.read(zpx()))
        elif o == 0x2D: self.A = self.setnz(self.A & self.read(ab()))
        elif o == 0x3D: self.A = self.setnz(self.A & self.read(abx()))
        elif o == 0x39: self.A = self.setnz(self.A & self.read(aby()))
        elif o == 0x21: self.A = self.setnz(self.A & self.read(izx()))
        elif o == 0x31: self.A = self.setnz(self.A & self.read(izy()))
        elif o == 0x09: self.A = self.setnz(self.A | imm())
        elif o == 0x05: self.A = self.setnz(self.A | self.read(zp()))
        elif o == 0x15: self.A = self.setnz(self.A | self.read(zpx()))
        elif o == 0x0D: self.A = self.setnz(self.A | self.read(ab()))
        elif o == 0x1D: self.A = self.setnz(self.A | self.read(abx()))
        elif o == 0x19: self.A = self.setnz(self.A | self.read(aby()))
        elif o == 0x01: self.A = self.setnz(self.A | self.read(izx()))
        elif o == 0x11: self.A = self.setnz(self.A | self.read(izy()))
        elif o == 0x49: self.A = self.setnz(self.A ^ imm())
        elif o == 0x45: self.A = self.setnz(self.A ^ self.read(zp()))
        elif o == 0x55: self.A = self.setnz(self.A ^ self.read(zpx()))
        elif o == 0x4D: self.A = self.setnz(self.A ^ self.read(ab()))
        elif o == 0x5D: self.A = self.setnz(self.A ^ self.read(abx()))
        elif o == 0x59: self.A = self.setnz(self.A ^ self.read(aby()))
        elif o == 0x41: self.A = self.setnz(self.A ^ self.read(izx()))
        elif o == 0x51: self.A = self.setnz(self.A ^ self.read(izy()))
        # 比較
        elif o == 0xC9: cmp_(self.A, imm())
        elif o == 0xC5: cmp_(self.A, self.read(zp()))
        elif o == 0xD5: cmp_(self.A, self.read(zpx()))
        elif o == 0xCD: cmp_(self.A, self.read(ab()))
        elif o == 0xDD: cmp_(self.A, self.read(abx()))
        elif o == 0xD9: cmp_(self.A, self.read(aby()))
        elif o == 0xC1: cmp_(self.A, self.read(izx()))
        elif o == 0xD1: cmp_(self.A, self.read(izy()))
        elif o == 0xE0: cmp_(self.X, imm())
        elif o == 0xE4: cmp_(self.X, self.read(zp()))
        elif o == 0xEC: cmp_(self.X, self.read(ab()))
        elif o == 0xC0: cmp_(self.Y, imm())
        elif o == 0xC4: cmp_(self.Y, self.read(zp()))
        elif o == 0xCC: cmp_(self.Y, self.read(ab()))
        # BIT
        elif o == 0x24: bit(self.read(zp()))
        elif o == 0x2C: bit(self.read(ab()))
        # シフト
        elif o == 0x0A: self.A = asl(self.A)
        elif o == 0x06: a = zp(); self.write(a, asl(self.read(a)))
        elif o == 0x16: a = zpx(); self.write(a, asl(self.read(a)))
        elif o == 0x0E: a = ab(); self.write(a, asl(self.read(a)))
        elif o == 0x1E: a = abx(); self.write(a, asl(self.read(a)))
        elif o == 0x4A: self.A = lsr(self.A)
        elif o == 0x46: a = zp(); self.write(a, lsr(self.read(a)))
        elif o == 0x56: a = zpx(); self.write(a, lsr(self.read(a)))
        elif o == 0x4E: a = ab(); self.write(a, lsr(self.read(a)))
        elif o == 0x5E: a = abx(); self.write(a, lsr(self.read(a)))
        elif o == 0x2A: self.A = rol(self.A)
        elif o == 0x26: a = zp(); self.write(a, rol(self.read(a)))
        elif o == 0x36: a = zpx(); self.write(a, rol(self.read(a)))
        elif o == 0x2E: a = ab(); self.write(a, rol(self.read(a)))
        elif o == 0x3E: a = abx(); self.write(a, rol(self.read(a)))
        elif o == 0x6A: self.A = ror(self.A)
        elif o == 0x66: a = zp(); self.write(a, ror(self.read(a)))
        elif o == 0x76: a = zpx(); self.write(a, ror(self.read(a)))
        elif o == 0x6E: a = ab(); self.write(a, ror(self.read(a)))
        elif o == 0x7E: a = abx(); self.write(a, ror(self.read(a)))
        # INC/DEC
        elif o == 0xE6: a = zp(); self.write(a, self.setnz(self.read(a)+1))
        elif o == 0xF6: a = zpx(); self.write(a, self.setnz(self.read(a)+1))
        elif o == 0xEE: a = ab(); self.write(a, self.setnz(self.read(a)+1))
        elif o == 0xFE: a = abx(); self.write(a, self.setnz(self.read(a)+1))
        elif o == 0xC6: a = zp(); self.write(a, self.setnz(self.read(a)-1))
        elif o == 0xD6: a = zpx(); self.write(a, self.setnz(self.read(a)-1))
        elif o == 0xCE: a = ab(); self.write(a, self.setnz(self.read(a)-1))
        elif o == 0xDE: a = abx(); self.write(a, self.setnz(self.read(a)-1))
        else:
            raise Exception(f"unknown opcode ${o:02X} at ${pc:04X}")

    # ---------- frame ----------
    def run_frame(self, pad=0, insns=12000):
        self.pad_state = pad
        self.vram_writes_this_frame = 0
        self.vbl = True
        if self.ppuctrl & 0x80:
            self.nmi()
        for _ in range(insns):
            self.step()
        self.frame += 1
        self.max_vram_writes = max(self.max_vram_writes, self.vram_writes_this_frame)

NES_PALETTE = [
 (84,84,84),(0,30,116),(8,16,144),(48,0,136),(68,0,100),(92,0,48),(84,4,0),(60,24,0),
 (32,42,0),(8,58,0),(0,64,0),(0,60,0),(0,50,60),(0,0,0),(0,0,0),(0,0,0),
 (152,150,152),(8,76,196),(48,50,236),(92,30,228),(136,20,176),(160,20,100),(152,34,32),(120,60,0),
 (84,90,0),(40,114,0),(8,124,0),(0,118,40),(0,102,120),(0,0,0),(0,0,0),(0,0,0),
 (236,238,236),(76,154,236),(120,124,236),(176,98,236),(228,84,236),(236,88,180),(236,106,100),(212,136,32),
 (160,170,0),(116,196,0),(76,208,32),(56,204,108),(56,180,204),(60,60,60),(0,0,0),(0,0,0),
 (236,238,236),(168,204,236),(188,188,236),(212,178,236),(236,174,236),(236,174,212),(236,180,176),(228,196,144),
 (204,210,120),(180,222,120),(168,226,144),(152,226,180),(160,214,228),(160,162,160),(0,0,0),(0,0,0)]

def render(nes, path, scale=2):
    W,H = 256,240
    fb = [[NES_PALETTE[nes.pal[0] & 0x3F]]*W for _ in range(H)]
    fb = [row[:] for row in fb]
    if nes.ppumask & 0x08:
        sx = nes.scroll_x + ((nes.ppuctrl & 1) << 8)
        for y in range(H):
            for x in range(W):
                wx = (x + sx) % 512
                nt = 0x400 if wx >= 256 else 0
                cx, cy = (wx % 256)//8, y//8
                ti = nes.vram[nes.ntaddr(0x000 + nt + cy*32 + cx)]
                base = 0x1000 if nes.ppuctrl & 0x10 else 0
                fy, fx = y & 7, wx & 7
                lo = nes.chr[base + ti*16 + fy]; hi = nes.chr[base + ti*16 + 8 + fy]
                b = 7 - fx
                v = ((lo>>b)&1) | (((hi>>b)&1)<<1)
                at = nes.vram[nes.ntaddr(0x3C0 + nt + (cy//4)*8 + cx//4)]
                shift = ((cy & 2) << 1) | (cx & 2)
                p = (at >> shift) & 3
                if v: fb[y][x] = NES_PALETTE[nes.pal[p*4+v] & 0x3F]
    if nes.ppumask & 0x10:
        for s in range(63,-1,-1):
            sy, ti, at, sx0 = nes.oam[s*4:s*4+4]
            if sy >= 0xEF: continue
            base = 0x1000 if nes.ppuctrl & 8 else 0
            for fy in range(8):
                y = sy + 1 + fy
                if y >= H: continue
                lo = nes.chr[base + ti*16 + (7-fy if at&0x80 else fy)]
                hi = nes.chr[base + ti*16 + 8 + (7-fy if at&0x80 else fy)]
                for fx in range(8):
                    x = sx0 + fx
                    if x >= W: continue
                    b = fx if at&0x40 else 7-fx
                    v = ((lo>>b)&1) | (((hi>>b)&1)<<1)
                    if v: fb[y][x] = NES_PALETTE[nes.pal[16 + (at&3)*4 + v] & 0x3F]
    rows = b''
    for y in range(H):
        for _ in range(scale):
            row = b'\x00'
            for x in range(W):
                row += bytes(fb[y][x]) * scale
            rows += row
    def chunk(t,d):
        return struct.pack('>I',len(d))+t+d+struct.pack('>I',zlib.crc32(t+d)&0xffffffff)
    ihdr = struct.pack('>IIBBBBB',W*scale,H*scale,8,2,0,0,0)
    png = b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',ihdr)+chunk(b'IDAT',zlib.compress(rows,6))+chunk(b'IEND',b'')
    open(path,'wb').write(png)

# パッドビット (シフト順: A,B,SEL,ST,U,D,L,R → bit0から)
A_=0x01; B_=0x02; SEL=0x04; ST=0x08; UP=0x10; DN=0x20; LF=0x40; RI=0x80
