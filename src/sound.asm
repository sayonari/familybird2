;==============================================================================
; FamilyBird2 サウンドドライバ "SAYODRV"
;   - 5ch (SQ1/SQ2/TRI/NOI/DPCM) 音楽再生
;   - 音量エンベロープ音色，$4003書き込みスキップ(位相リセットノイズ対策)
;   - SFX 2系統 (SQ2/NOI を一時奪取，音楽より優先)
;   使い方:
;     sound_init      : 起動時1回
;     A=曲番号(1-) -> jsr music_play  / A=0 -> 停止
;     A=SFX番号    -> jsr sfx_play
;     毎フレーム(NMI内) jsr sound_update
;==============================================================================

; --- ゼロページ (main.asm の割当と衝突しないこと) ---
SND_PTR		.equ	$50	; $50-$59: 各ch ストリームポインタ (5ch x 2)
SFXA_PTR	.equ	$5A	; SFXスロットA ポインタ
SFXB_PTR	.equ	$5C	; SFXスロットB ポインタ
SND_ENVP	.equ	$5E	; エンベロープ/汎用テンポラリポインタ ($5E,$5F)
SND_CH		.equ	$4D	; 処理中ch番号

; --- 絶対RAM ---
SND_RAM		.equ	$0500
snd_wait	.equ	SND_RAM+$00	; +0..4 : 各ch 残フレーム
snd_note	.equ	SND_RAM+$05	; +5..9 : 各ch 現在ノート
snd_inst	.equ	SND_RAM+$0A	; +10..14: 各ch 音色番号
snd_envpos	.equ	SND_RAM+$0F	; +15..19: 各ch エンベロープ位置
snd_keyon	.equ	SND_RAM+$14	; +20..24: 各ch 発音中フラグ
snd_hicache	.equ	SND_RAM+$19	; +25,26 : SQ1/SQ2 $4003キャッシュ
snd_playing	.equ	SND_RAM+$1B	; 曲再生中フラグ
sfxa_wait	.equ	SND_RAM+$1C
sfxa_on		.equ	SND_RAM+$1D
sfxb_wait	.equ	SND_RAM+$1E
sfxb_on		.equ	SND_RAM+$1F
snd_tick	.equ	SND_RAM+$20	; ビブラート用フレームカウンタ
snd_perlo	.equ	SND_RAM+$21	; +33..35 : SQ1/SQ2/TRI 基準周期(下位)
snd_perhi	.equ	SND_RAM+$24	; +36..38 : 同(上位)

;==============================================================================
; 初期化
;==============================================================================
sound_init:
	lda #$40
	sta $4017		; フレームカウンタ IRQ禁止
	lda #$0F
	sta $4015		; DPCM以外有効
	lda #$08
	sta $4001		; スイープ無効
	sta $4005
	lda #$30
	sta $4000		; 無音
	sta $4004
	sta $400C
	lda #$00
	sta $4008
	sta $4010
	sta snd_playing
	sta sfxa_on
	sta sfxb_on
	ldx #9
.clrp
	sta <SND_PTR,x
	dex
	bpl .clrp
	rts

;==============================================================================
; 曲再生開始  IN A: 曲番号 (0=停止, 1〜)
;==============================================================================
music_play:
	pha
	jsr music_stop
	pla
	bne .start
	rts			; 0なら停止のみ
.start
	sec
	sbc #1
	; Y = A*10 (song_tableは1曲あたり5ch x 2byte)
	sta <SND_ENVP
	asl a			; x2
	sta <SND_ENVP+1
	asl a			; x4
	asl a			; x8
	clc
	adc <SND_ENVP+1		; x10
	tay
	; 5ch分のポインタコピー (ZPオフセットとテーブルオフセットは同歩調)
	ldx #0
.setptr
	lda song_table,y
	sta <SND_PTR,x
	iny
	lda song_table,y
	sta <SND_PTR+1,x
	iny
	inx
	inx
	cpx #10
	bne .setptr
	; ch状態初期化
	ldx #4
.setch
	lda #1
	sta snd_wait,x		; 次フレームでイベント読み出し開始
	lda #0
	sta snd_keyon,x
	sta snd_envpos,x
	sta snd_inst,x
	dex
	bpl .setch
	lda #1
	sta snd_playing
	lda #$FF
	sta snd_hicache
	sta snd_hicache+1
	rts

;==============================================================================
; 曲停止
;==============================================================================
music_stop:
	lda #0
	sta snd_playing
	ldx #9
.clrp
	sta <SND_PTR,x
	dex
	bpl .clrp
	ldx #4
.clrk
	sta snd_keyon,x
	dex
	bpl .clrk
	lda #$30
	sta $4000
	sta $4004
	sta $400C
	lda #$00
	sta $4008
	lda #$0F
	sta $4015		; DPCM停止
	rts

;==============================================================================
; SFX再生  IN A: SFX番号
;==============================================================================
sfx_play:
	tax
	lda sfx_chan_table,x	; 0=SQ2 / 1=NOI
	pha
	txa
	asl a
	tax
	lda sfx_table,x
	sta <SND_ENVP
	lda sfx_table+1,x
	sta <SND_ENVP+1
	pla
	bne .noise
	; パルス2スロット
	lda <SND_ENVP
	sta <SFXA_PTR
	lda <SND_ENVP+1
	sta <SFXA_PTR+1
	lda #1
	sta sfxa_on
	sta sfxa_wait
	rts
.noise
	lda <SND_ENVP
	sta <SFXB_PTR
	lda <SND_ENVP+1
	sta <SFXB_PTR+1
	lda #1
	sta sfxb_on
	sta sfxb_wait
	rts

;==============================================================================
; 毎フレーム更新
;==============================================================================
sound_update:
	inc snd_tick
	jsr music_update
	jsr sfx_update
	rts

;------------------------------------------------------------------------------
; 音楽更新
;------------------------------------------------------------------------------
music_update:
	lda snd_playing
	bne .go
	rts
.go
	ldx #0			; ch番号
.chloop
	txa
	pha
	jsr mus_ch_update
	pla
	tax
	inx
	cpx #5
	bne .chloop
	rts

; --- 1ch分の更新  IN X: ch番号(0-4) ---
mus_ch_update:
	stx <SND_CH
	txa
	asl a
	tax
	lda <SND_PTR,x
	ora <SND_PTR+1,x
	bne .active
	ldx <SND_CH
	rts			; 未使用/停止ch
.active
	ldx <SND_CH
	dec snd_wait,x
	beq .readevents
	jmp mus_ch_envelope	; 発音継続中 -> エンベロープのみ
.readevents
.evloop
	lda <SND_CH
	asl a
	tax
	lda <SND_PTR,x		; ポインタをテンポラリへ
	sta <SND_ENVP
	lda <SND_PTR+1,x
	sta <SND_ENVP+1
	ldx <SND_CH
	ldy #0
	lda [SND_ENVP],y	; イベントバイト
	cmp #$80
	bcc .noteon
	beq .rest
	cmp #$81
	beq .setinst
	cmp #$82
	beq .jump
	; --- $83 halt ---
	lda <SND_CH
	asl a
	tax
	lda #0
	sta <SND_PTR,x
	sta <SND_PTR+1,x
	ldx <SND_CH
	lda #0
	sta snd_keyon,x
	jmp mus_ch_silence
.setinst
	iny
	lda [SND_ENVP],y
	sta snd_inst,x
	jsr mus_ptr_add2
	jmp .evloop
.jump
	iny
	lda [SND_ENVP],y
	pha
	iny
	lda [SND_ENVP],y
	pha
	lda <SND_CH
	asl a
	tax
	pla
	sta <SND_PTR+1,x
	pla
	sta <SND_PTR,x
	ldx <SND_CH
	jmp .evloop
.rest
	iny
	lda [SND_ENVP],y
	sta snd_wait,x
	lda #0
	sta snd_keyon,x
	jsr mus_ptr_add2
	jmp mus_ch_silence
.noteon
	sta snd_note,x
	iny
	lda [SND_ENVP],y
	sta snd_wait,x
	lda #1
	sta snd_keyon,x
	lda #0
	sta snd_envpos,x
	jsr mus_ptr_add2
	jsr mus_ch_trigger
	jmp mus_ch_envelope

; --- ポインタ+2 IN X:ch (X保存) ---
mus_ptr_add2:
	txa
	asl a
	tax
	lda <SND_PTR,x
	clc
	adc #2
	sta <SND_PTR,x
	bcc .nc
	inc <SND_PTR+1,x
.nc
	ldx <SND_CH
	rts

;------------------------------------------------------------------------------
; ノートオン時のレジスタ書き込み IN X:ch (X保存)
;------------------------------------------------------------------------------
mus_ch_trigger:
	cpx #2
	beq .tri
	bcc .pulse
	cpx #3
	beq .noise
	; --- DPCM ---
	ldy snd_note,x
	lda #$0F
	sta $4015
	lda dpcm_rate_table,y
	sta $4010
	lda dpcm_addr_table,y
	sta $4012
	lda dpcm_len_table,y
	sta $4013
	lda #$1F
	sta $4015
	rts
.tri
	; --- 三角波 ---
	lda #$FF
	sta $4008
	ldy snd_note,x
	lda note_table_lo,y
	sta snd_perlo+2
	sta $400A
	lda note_table_hi,y
	sta snd_perhi+2
	sta $400B
	rts
.noise
	; --- ノイズ: note = 周期(0-15)  SFX再生中は触らない ---
	lda sfxb_on
	bne .nskip
	lda snd_note,x
	sta $400E
	lda #$08
	sta $400F
.nskip
	rts
.pulse
	; --- パルス1/2 (X=0/1) ---
	ldy snd_note,x
	lda note_table_lo,y
	sta snd_perlo,x
	lda note_table_hi,y
	sta snd_perhi,x
	cpx #0
	bne .p2
	lda snd_perlo
	sta $4002
	lda snd_perhi
	cmp snd_hicache
	beq .p1done
	sta snd_hicache
	sta $4003
.p1done
	rts
.p2
	; SFX再生中はレジスタに触らない (SFX終了時にhicache=$FFで復帰)
	lda sfxa_on
	bne .p2done
	lda snd_perlo+1
	sta $4006
	lda snd_perhi+1
	cmp snd_hicache+1
	beq .p2done
	sta snd_hicache+1
	sta $4007
.p2done
	rts

;------------------------------------------------------------------------------
; エンベロープ更新 (SQ1/SQ2/NOI)  IN X: ch
;------------------------------------------------------------------------------
mus_ch_envelope:
	cpx #2
	bcc .pulse
	beq .tri
	cpx #3
	beq .noise
	rts
.tri
	; TRIはビブラートのみ
	lda snd_keyon,x
	beq .tdone
	jsr snd_vibrato
.tdone
	rts
.pulse
	lda snd_keyon,x
	beq .off_p
	; SQ2はSFX再生中に触らない
	cpx #1
	bne .pgo
	lda sfxa_on
	bne .pdone
.pgo
	jsr mus_env_value	; A=音量
	ora #$30		; 定音量+レングス停止
	ldy snd_inst,x
	ora inst_duty,y		; dutyはbit7-6
	cpx #0
	bne .p2w
	sta $4000
	jmp .pfx
.p2w
	sta $4004
.pfx
	; 高速アルペジオ (疑似和音) があればビブラートより優先
	ldy snd_inst,x
	lda inst_arp,y
	beq .pvib
	jsr snd_arpeggio
	rts
.pvib
	jsr snd_vibrato
.pdone
	rts
.off_p
	jmp mus_ch_silence
.noise
	lda snd_keyon,x
	beq .off_n
	lda sfxb_on
	bne .ndone
	jsr mus_env_value
	ora #$30
	sta $400C
.ndone
	rts
.off_n
	jmp mus_ch_silence

;------------------------------------------------------------------------------
; ビブラート適用 IN X:ch(0/1/2, keyon中)  周期下位のみ揺らす($4003系は触らない)
;------------------------------------------------------------------------------
snd_vibrato:
	ldy snd_inst,x
	lda inst_vib,y
	bne .on
	rts
.on
	; 端の周期では境界跨ぎ防止のためスキップ
	pha
	lda snd_perlo,x
	cmp #$08
	bcc .skip2
	cmp #$F0
	bcs .skip2
	; インデクス = (tick>>2)&7
	lda snd_tick
	lsr a
	lsr a
	and #$07
	tay
	pla
	cmp #2
	beq .d2
	lda vib_tbl1,y
	jmp .add
.d2
	lda vib_tbl2,y
.add
	clc
	adc snd_perlo,x
	cpx #0
	beq .w0
	cpx #1
	beq .w1
	sta $400A
	rts
.w0
	sta $4002
	rts
.w1
	sta $4006
	rts
.skip2
	pla
	rts

vib_tbl1:	.db 0,1,1,0,0,$FF,$FF,0
vib_tbl2:	.db 0,1,2,1,0,$FF,$FE,$FF

;------------------------------------------------------------------------------
; 高速アルペジオ: 1フレームごとに和音構成音を巡回 (FAMICOMPO風疑似和音)
;  IN X:ch(0/1)  A:アルペジオ種別(1=メジャー 2=マイナー 3=オクターブ)
;  高音域(周期上位が基音と同じ範囲)でのみ音程変更する (位相リセット音回避)
;------------------------------------------------------------------------------
snd_arpeggio:
	; オフセット = arp_tblN[tick&3]
	sec
	sbc #1
	asl a
	asl a			; 種別*4
	sta <SND_ENVP
	lda snd_tick
	and #$03
	clc
	adc <SND_ENVP
	tay
	lda arp_tbl,y		; 半音オフセット
	clc
	adc snd_note,x
	tay			; 対象ノート
	lda note_table_hi,y
	cmp snd_perhi,x
	bne .skip		; 上位バイトが変わるなら書かない(低音域の保険)
	lda note_table_lo,y
	cpx #0
	bne .w1
	sta $4002
	rts
.w1
	sta $4006
.skip
	rts

arp_tbl:	.db 0,4,7,4		; メジャー
		.db 0,3,7,3		; マイナー
		.db 0,12,0,12		; オクターブ
		.db 0,5,9,5		; sus4風

; --- エンベロープ現在値を得て進める IN X:ch OUT A:音量(0-15) ---
mus_env_value:
	ldy snd_inst,x
	lda inst_env_lo,y
	sta <SND_ENVP
	lda inst_env_hi,y
	sta <SND_ENVP+1
	ldy snd_envpos,x
	lda [SND_ENVP],y
	cmp #$FF
	bne .adv
	; 終端: ひとつ前の値を維持
	dey
	lda [SND_ENVP],y
	rts
.adv
	inc snd_envpos,x
	rts

;------------------------------------------------------------------------------
; ch消音 IN X:ch (X保存)
;------------------------------------------------------------------------------
mus_ch_silence:
	cpx #2
	bcc .pulse
	beq .tri
	cpx #3
	beq .noise
	rts			; DPCMは打ちっぱなしでOK
.pulse
	cpx #0
	bne .p2s
	lda #$30
	sta $4000
	rts
.p2s
	; SFX動作中はSQ2に触らない
	lda sfxa_on
	bne .p2sk
	lda #$30
	sta $4004
.p2sk
	rts
.tri
	lda #$00
	sta $4008
	sta $400B		; リロードフラグ→カウンタ0で消音
	rts
.noise
	lda sfxb_on
	bne .nsk
	lda #$30
	sta $400C
.nsk
	rts

;------------------------------------------------------------------------------
; SFX更新
;   ストリーム: [dur, reg0, reg2, reg3] ... dur=0で終了
;   reg3=$FF なら$4007/$400F相当は書かない(位相維持)
;------------------------------------------------------------------------------
sfx_update:
	; --- スロットA (SQ2: $4004/$4006/$4007) ---
	lda sfxa_on
	beq .slotB
	dec sfxa_wait
	bne .slotB
	ldy #0
	lda [SFXA_PTR],y
	bne .playA
	; 終了
	sta sfxa_on
	lda #$30
	sta $4004
	lda #$FF
	sta snd_hicache+1	; 音楽側に$4007再書き込みさせる
	jmp .slotB
.playA
	sta sfxa_wait
	iny
	lda [SFXA_PTR],y
	sta $4004
	iny
	lda [SFXA_PTR],y
	sta $4006
	iny
	lda [SFXA_PTR],y
	cmp #$FF
	beq .nohiA
	sta $4007
	sta snd_hicache+1
.nohiA
	lda <SFXA_PTR
	clc
	adc #4
	sta <SFXA_PTR
	bcc .slotB
	inc <SFXA_PTR+1
.slotB
	; --- スロットB (NOI: $400C/$400E/$400F) ---
	lda sfxb_on
	beq .done
	dec sfxb_wait
	bne .done
	ldy #0
	lda [SFXB_PTR],y
	bne .playB
	sta sfxb_on
	lda #$30
	sta $400C
	rts
.playB
	sta sfxb_wait
	iny
	lda [SFXB_PTR],y
	sta $400C
	iny
	lda [SFXB_PTR],y
	sta $400E
	iny
	lda [SFXB_PTR],y
	cmp #$FF
	beq .nohiB
	sta $400F
.nohiB
	lda <SFXB_PTR
	clc
	adc #4
	sta <SFXB_PTR
	bcc .done
	inc <SFXB_PTR+1
.done
	rts

;==============================================================================
; SFXデータ
;   0:羽ばたき 1:得点 2:衝突 3:アイテム 4:スター 5:決定
;   [dur, $4004(vol/duty), $4006(periodL), $4007(periodH/または$FF=書かない)]
;==============================================================================
sfx_table:
	.dw sfx_flap
	.dw sfx_point
	.dw sfx_hit
	.dw sfx_item
	.dw sfx_star
	.dw sfx_select
	.dw sfx_fanfare
	.dw sfx_wind
sfx_chan_table:
	.db 0,0,1,0,0,0,0,1	; 0=SQ2, 1=NOI

; 羽ばたき: 短い下降ブリップ「ピュッ」
sfx_flap:
	.db 2, $7A, $60, $00
	.db 2, $78, $90, $FF
	.db 2, $75, $C8, $FF
	.db 2, $72, $F8, $FF
	.db 0

; 得点(コイン風): B5 -> E6
sfx_point:
	.db 3, $BF, $70, $00
	.db 4, $BE, $54, $00
	.db 4, $BB, $54, $FF
	.db 4, $B8, $54, $FF
	.db 4, $B5, $54, $FF
	.db 4, $B2, $54, $FF
	.db 0

; 衝突: ノイズ「ドカッ」
sfx_hit:
	.db 3, $3F, $0C, $08
	.db 3, $3C, $0E, $FF
	.db 4, $38, $09, $08
	.db 6, $34, $0B, $FF
	.db 6, $32, $0D, $FF
	.db 0

; アイテム取得: 上昇アルペジオ C6-E6-G6-C7
sfx_item:
	.db 3, $BB, $6A, $00
	.db 3, $BB, $54, $FF
	.db 3, $BB, $46, $FF
	.db 5, $BA, $35, $FF
	.db 4, $B6, $35, $FF
	.db 4, $B3, $35, $FF
	.db 0

; スター: キラキラ上昇ラン
sfx_star:
	.db 3, $BC, $6A, $00
	.db 3, $BC, $54, $FF
	.db 3, $BC, $46, $FF
	.db 3, $BC, $35, $FF
	.db 3, $BC, $29, $FF
	.db 3, $BC, $23, $FF
	.db 6, $B9, $1A, $FF
	.db 4, $B5, $1A, $FF
	.db 0

; 決定音
sfx_select:
	.db 2, $B8, $46, $00
	.db 6, $B6, $35, $FF
	.db 0

; 風: やわらかいヒュー
sfx_wind:
	.db 10, $31, $0E, $08
	.db 10, $32, $0D, $FF
	.db 12, $33, $0C, $FF
	.db 12, $32, $0D, $FF
	.db 12, $31, $0E, $FF
	.db 0

; 節目ファンファーレ (10点ごと): タ・ダー!
sfx_fanfare:
	.db 5, $BD, $8D, $00
	.db 4, $BE, $6A, $00
	.db 4, $BB, $6A, $FF
	.db 5, $B7, $6A, $FF
	.db 6, $B3, $6A, $FF
	.db 0
