;==============================================================================
; FamilyBird 2  --  クリーン再実装版
;   2026  Ryota NISHIMURA (JAPAN) + Claude
;   原作: FamilyBird (2014/04/28) by Ryota NISHIMURA
;
; 原作からの主な改善:
;   - ゲームロジックをメインスレッドへ (NMIはDMA/VRAMバッファ転送/サウンドのみ)
;   - VRAM書き込みはすべてVBlank内 (バッファ経由) → 画面化け解消
;   - 数学的当たり判定 (VRAM読み出し判定を廃止)
;   - 垂直ミラーリング + 2画面ネームテーブルで無限横スクロール
;   - 土管は4スロット循環 (画面外で再生成)，スコア上昇で上下移動
;   - アイテム (コイン/スター/チェリー)
;   - 自作サウンドドライバ (DPCM打楽器つき5ch)
;==============================================================================

	.inesprg 2		; PRG-ROM 32KB
	.ineschr 1		; CHR-ROM 8KB
	.inesmir 1		; 垂直ミラーリング (横スクロール用)
	.inesmap 0		; NROM

;------------------------------------------------------------------------------
; PPU/APUレジスタ
;------------------------------------------------------------------------------
PPUCTRL		.equ	$2000
PPUMASK		.equ	$2001
PPUSTAT		.equ	$2002
OAMADDR		.equ	$2003
PPUSCROLL	.equ	$2005
PPUADDR		.equ	$2006
PPUDATA		.equ	$2007
SPRDMA		.equ	$4014

;------------------------------------------------------------------------------
; 定数
;------------------------------------------------------------------------------
BIRD_X		.equ	60	; 鳥の画面X座標(固定)
BIRD_Y_INIT	.equ	120
GAP_ROWS	.equ	9	; 土管ゲートの縦幅(行)
GAP_MIN		.equ	3	; ゲート上端の最小行
GAP_MAX		.equ	14	; ゲート上端の最大行
GRAVITY		.equ	$30	; 重力 (8.8固定小数, /frame)
FLAP_VEL_HI	.equ	$FD	; 羽ばたき初速 (-2.75px/f = $FD40)
FLAP_VEL_LO	.equ	$40
MAXFALL_HI	.equ	$04	; 最大落下速度 4px/f
GROUND_Y	.equ	178	; 地面衝突Y(鳥の上端基準)
MOVE_PERIOD	.equ	14	; 移動土管の1ステップフレーム数
STAR_TIME	.equ	180	; スター無敵時間 x2フレーム(下記で2回デクリメント調整)

; シーン番号
SC_LOGO		.equ	0
SC_TITLE	.equ	1
SC_GAME		.equ	2
SC_OVER		.equ	3
SC_STAFF	.equ	4
SC_AWARDS	.equ	5

; ゲーム内状態
GS_WAIT		.equ	0
GS_RUN		.equ	1
GS_DEAD		.equ	2

; パッドビット
PAD_A		.equ	%10000000
PAD_B		.equ	%01000000
PAD_SL		.equ	%00100000
PAD_ST		.equ	%00010000
PAD_UP		.equ	%00001000
PAD_DN		.equ	%00000100
PAD_LF		.equ	%00000010
PAD_RI		.equ	%00000001

; 文字→CHR変換 ('0'=$30 → CHR $C0)
STR2CHR		.equ	$90
TILE_SKY	.equ	$EC

; SFX番号
SE_FLAP		.equ	0
SE_POINT	.equ	1
SE_HIT		.equ	2
SE_ITEM		.equ	3
SE_STAR		.equ	4
SE_SELECT	.equ	5
SE_FANFARE	.equ	6
SE_WIND		.equ	7

; 曲番号
MUS_TITLE	.equ	1
MUS_STAGE	.equ	2
MUS_OVER	.equ	3
MUS_STAFF	.equ	4
MUS_IDOL	.equ	5
MUS_CUTE	.equ	6
MUS_STAR	.equ	7
MUS_HERO	.equ	8
MUS_SWING	.equ	9
MUS_TURK	.equ	10
MUS_ENT	.equ	11
MUS_CANCAN	.equ	12
MUS_KOROB	.equ	13
MUS_TECH	.equ	14

;------------------------------------------------------------------------------
; ゼロページ変数
;------------------------------------------------------------------------------
T0		.equ	$00	; 汎用テンポラリ
T1		.equ	$01
T2		.equ	$02
T3		.equ	$03
T4		.equ	$04
T5		.equ	$05
T6		.equ	$06
T7		.equ	$07
PTR_L		.equ	$08	; 汎用ポインタ
PTR_H		.equ	$09

SCENE		.equ	$0E
FRAME_DONE	.equ	$0F	; NMI完了フラグ (メインループ同期)
PPU_ON		.equ	$10	; 描画中フラグ (NMIのバッファ転送許可)
FRAME_CNT	.equ	$13
RNG		.equ	$14	; 乱数
SCROLL_L	.equ	$15	; スクロールX (0-511)
SCROLL_H	.equ	$16
GAME_ST		.equ	$19	; ゲーム内状態 (GS_*)
SCORE		.equ	$1A	; $1A-$1F: 6桁 (10進, 下位桁から)
HISCORE		.equ	$26	; $26-$2B: ハイスコア6桁

PAD_ON		.equ	$20	; 現在押下ボタン
PAD_TRG		.equ	$21	; 今フレーム押下ボタン
PAD_OLD		.equ	$22
PAD_TMP		.equ	$23

BIRD_Y		.equ	$30	; Y座標(整数部)
BIRD_YF		.equ	$31	; Y座標(小数部)
VEL_L		.equ	$32	; Y速度 (8.8固定小数, 符号付き)
VEL_H		.equ	$33
BIRD_SPR	.equ	$34	; スプライトベースタイル
BIRD_ANIM	.equ	$35	; アニメカウンタ
CHARA_NO	.equ	$36	; キャラ番号 0-4
STAR_TIMER	.equ	$37	; 無敵残り時間
BOB_CNT		.equ	$38	; 待機中の浮遊カウンタ
SCR_TIMER	.equ	$3B	; シーンタイマー
SCR_TIMER_S	.equ	$3C
CURSOR		.equ	$3D	; タイトルメニューカーソル
INITED		.equ	$3E
BUF_READY	.equ	$40	; VRAMバッファ転送要求
BUF_LEN		.equ	$41	; VRAMバッファ書き込み位置
PAL_DIRTY	.equ	$42	; パレット転送要求
STAGE_BGM	.equ	$3F	; 今プレイのステージ曲番号
GOLDSCORE	.equ	$39	; ハイスコア更新中フラグ(スコア金色表示)
TITLE_MODE	.equ	$2C	; タイトル状態 0=通常 1=隠しスクロール中 2=隠し部屋
COMBO		.equ	$24	; コイン連続取得コンボ (0-4でキャップ)
GAPSZ_TMP	.equ	$25	; ColMake用: ゲート幅
WIND_DIR	.equ	$0A	; 風向き 0=なし 1=上昇 $FF=下降
WIND_TMR	.equ	$0B	; 風タイマー (4フレームごとに減算)
IDLE_CNT	.equ	$2D	; タイトル放置カウンタ (4フレームごと+1)
SECRET_GIFT	.equ	$2E	; 隠し部屋からの開始 = スター無敵スタート
SCROLL_Y	.equ	$2F	; Yスクロール (タイトル隠し演出用)
SCROLL_F	.equ	$43	; スクロール小数部
SPEED_ADD	.equ	$44	; スクロール加算小数 (スコアで増える)
PALPHASE	.equ	$45	; パレット位相 (昼/夕/夜)
PAUSED		.equ	$46	; ポーズ中
NEWREC		.equ	$47	; ハイスコア更新フラグ
SCORE_DIRTY	.equ	$48
FLAP_HOLD	.equ	$49	; 羽ばたきアニメ用
PUSHA_BLINK	.equ	$4A
SLOT_TMP	.equ	$4B
ITEM_IDX	.equ	$4C
DRAW_C0		.equ	$4E	; 土管描画 開始列(0-3)
DRAW_C1		.equ	$4F	; 土管描画 終了列(0-3)

; $50-$5F : サウンドドライバ用 (sound.asm参照)

;------------------------------------------------------------------------------
; 絶対RAM
;------------------------------------------------------------------------------
OAM_BUF		.equ	$0200	; OAMシャドウ
VBUF		.equ	$0300	; VRAM更新バッファ [len|addrH|addrL|data...] len=0終端
				;   addrH bit7=1: +32モード(縦書き)
VBUF_MAX	.equ	$B0	; バッファ容量

; 土管スロット (4本, 16列間隔で循環)
PIPE_ACT	.equ	$0400	; +0-3: 土管あり
PIPE_GAP	.equ	$0404	; ゲート上端行
PIPE_MOV	.equ	$0408	; 移動中フラグ
PIPE_DIR	.equ	$040C	; 移動方向 (1 or $FF)
PIPE_CNT	.equ	$0410	; 移動タイマー
PIPE_PASS	.equ	$0414	; 通過済み(得点済み)
PIPE_RECYC	.equ	$0418	; 再生成フェーズ (0=未 5..2=列0..3描画待ち 1=完了)
PIPE_MOVPH	.equ	$041C	; 移動再描画フェーズ (1=下側窓が未描画)
PIPE_BOSS	.equ	$04A0	; +0-3: ボス土管フラグ
WP_X		.equ	$04A8	; 風パーティクルX (6個)
POP_X		.equ	$04B6	; 得点ポップX
POP_Y		.equ	$04B7	; 得点ポップY
POP_T		.equ	$04B8	; 得点ポップ残フレーム
POP_D1		.equ	$04B9	; 十の位タイル ($FF=なし)
POP_D2		.equ	$04BA	; 一の位タイル
WP_Y		.equ	$04AE	; 風パーティクルY (6個)
PIPE_GAPSZ	.equ	$04A4	; +0-3: ゲート幅(行数)

; アイテム (2個)
ITEM_ACT	.equ	$0420	; +0,1: 有効
ITEM_TYPE	.equ	$0422	; 0=コイン 1=スター 2=チェリー
ITEM_XL		.equ	$0424	; NT空間X (0-511)
ITEM_XH		.equ	$0426
ITEM_Y		.equ	$0428
ITEM_ANIM	.equ	$042A
ITEM_ARM	.equ	$042C	; 画面右から入場済みフラグ

COLBUF		.equ	$0430	; 列タイル生成バッファ (30行)

; 星パーティクル (5個, スプライト30-34)
PART_X		.equ	$0470
PART_Y		.equ	$0475
PART_DX		.equ	$047A
PART_DY		.equ	$047F
PART_LIFE	.equ	$0484
PAL_BUF		.equ	$04C0	; パレットシャドウ 32byte

; --- 実績 (リセットしても消えないよう$0700ページに署名つきで保持) ---
ACH_FLAGS	.equ	$07F0	; 実績ビット (b0:初得点 b1:ランク2 b2:ランク4 b3:ランク5
				;  b4:コンボMAX b5:スター b6:隠しページ b7:ボス)
ACH_MAGIC0	.equ	$07F2	; 署名 'F'
ACH_MAGIC1	.equ	$07F3	; 署名 'B'
ACH_HISCORE	.equ	$07F4	; ハイスコアのミラー (6桁)

; $0500-$05FF : サウンドドライバ用 (sound.asm参照)

;==============================================================================
; バンク0 ($8000-)  メインプログラム
;==============================================================================
	.bank 0
	.org $8000

;------------------------------------------------------------------------------
; リセット
;------------------------------------------------------------------------------
Reset:
	sei
	cld
	ldx #$40
	stx $4017		; APUフレームIRQ禁止
	ldx #$FF
	txs
	inx			; X=0
	stx PPUCTRL		; NMI禁止
	stx PPUMASK		; 描画OFF
	stx $4010		; DPCM IRQ禁止

	; VBlank待ち x2 (PPU安定化)
	bit PPUSTAT
.vw1
	bit PPUSTAT
	bpl .vw1
	; 実績署名チェック (リセットでは実績とハイスコアを保持)
	ldy #0			; Y=0:初回起動 1:署名あり
	lda ACH_MAGIC0
	cmp #'F'
	bne .fresh
	lda ACH_MAGIC1
	cmp #'B'
	bne .fresh
	iny
.fresh
	; RAMクリア ($0700ページは署名ありなら保持)
	lda #$00
	tax
.clrram
	sta $0000,x
	sta $0100,x
	sta $0300,x
	sta $0400,x
	sta $0500,x
	sta $0600,x
	inx
	bne .clrram
	cpy #1
	beq .keep700
	lda #$00
	tax
.clr700
	sta $0700,x
	inx
	bne .clr700
	lda #'F'
	sta ACH_MAGIC0
	lda #'B'
	sta ACH_MAGIC1
	jmp .resdone
.keep700
	; ハイスコアをミラーから復元
	ldx #5
.hires
	lda ACH_HISCORE,x
	sta <HISCORE,x
	dex
	bpl .hires
.resdone
	; OAMシャドウは画面外へ
	jsr SpriteInit
.vw2
	bit PPUSTAT
	bpl .vw2

	; サウンド初期化
	jsr sound_init

	lda #1
	sta <RNG

	; SHOKOロゴシーンから
	lda #SC_LOGO
	sta <SCENE
	lda #0
	sta <INITED

	; NMI許可 (描画はシーン初期化側でON)
	lda #%10001000		; NMI有効, SPRパタン$1000, BGパタン$0000
	sta PPUCTRL

;------------------------------------------------------------------------------
; メインループ (ゲームロジックはすべてここ; NMIと分離)
;------------------------------------------------------------------------------
MainLoop:
	; NMI完了待ち
.wait
	lda <FRAME_DONE
	beq .wait
	lda #0
	sta <FRAME_DONE

	jsr PadRead
	jsr RngStep

	; シーン分岐
	lda <SCENE
	cmp #SC_LOGO
	bne .n1
	jsr SceneLogo
	jmp MainLoop
.n1
	cmp #SC_TITLE
	bne .n2
	jsr SceneTitle
	jmp MainLoop
.n2
	cmp #SC_GAME
	bne .n3
	jsr SceneGame
	jmp MainLoop
.n3
	cmp #SC_OVER
	bne .n4
	jsr SceneOver
	jmp MainLoop
.n4
	cmp #SC_STAFF
	bne .n5
	jsr SceneStaff
	jmp MainLoop
.n5
	jsr SceneAwards
	jmp MainLoop

;------------------------------------------------------------------------------
; NMIハンドラ: OAM DMA / VRAMバッファ転送 / スクロール設定 / サウンド
;------------------------------------------------------------------------------
NMI:
	pha
	txa
	pha
	tya
	pha

	lda <PPU_ON
	beq .nogfx		; 描画OFF中(シーン構築中)はPPUに一切触らない
	bit PPUSTAT		; アドレスラッチクリア

	; --- OAM DMA ---
	lda #$00
	sta OAMADDR
	lda #high(OAM_BUF)
	sta SPRDMA

	; --- VRAMバッファ転送 ---
	lda <BUF_READY
	beq .nobuf
	jsr VbufFlush
	lda #0
	sta <BUF_READY
	sta <BUF_LEN
	lda #0
	sta VBUF
.nobuf
	; --- パレット転送 ---
	lda <PAL_DIRTY
	beq .nopal
	lda #%10001000		; +1モードに戻す (バッファ転送が+32のままの場合がある)
	sta PPUCTRL
	lda #$3F
	sta PPUADDR
	lda #$00
	sta PPUADDR
	ldx #0
.palcp
	lda PAL_BUF,x
	sta PPUDATA
	inx
	cpx #32
	bne .palcp
	lda #0
	sta <PAL_DIRTY
.nopal
	; --- 描画ON要求 (PPU_ON=2 -> VBlank内でON) ---
	lda <PPU_ON
	cmp #2
	bne .noturn
	lda #%00011110		; スプライト+BG表示ON
	sta PPUMASK
	lda #1
	sta <PPU_ON
.noturn
	; --- スクロール設定 ---
	lda <SCROLL_H
	and #$01		; bit0 -> ネームテーブル選択
	ora #%10001000
	sta PPUCTRL
	lda <SCROLL_L
	sta PPUSCROLL
	lda <SCROLL_Y
	sta PPUSCROLL
.nogfx
	; --- サウンド (毎フレーム必ず) ---
	jsr sound_update

	inc <FRAME_CNT
	lda #1
	sta <FRAME_DONE

	pla
	tay
	pla
	tax
	pla
IRQ:
	rti

;------------------------------------------------------------------------------
; VRAMバッファ転送 (NMI内から呼ばれる)
;------------------------------------------------------------------------------
VbufFlush:
	ldx #0
.entry
	lda VBUF,x		; len
	beq .done
	sta <T0
	inx
	lda VBUF,x		; addrH (bit7=縦書き)
	bpl .horiz
	and #$3F
	sta <T1
	lda #%10001100		; +32モード
	sta PPUCTRL
	jmp .setaddr
.horiz
	sta <T1
	lda #%10001000		; +1モード
	sta PPUCTRL
.setaddr
	lda <T1
	sta PPUADDR
	inx
	lda VBUF,x
	sta PPUADDR
	inx
	ldy <T0
.data
	lda VBUF,x
	sta PPUDATA
	inx
	dey
	bne .data
	jmp .entry
.done
	rts

;------------------------------------------------------------------------------
; パッド読み取り (DPCM再生中のバス衝突対策で一致するまで再読)
;------------------------------------------------------------------------------
PadRead:
	jsr PadReadOnce
	lda <PAD_TMP
	pha
	jsr PadReadOnce
	pla
	cmp <PAD_TMP
	bne PadRead		; 不一致なら再読
	; トリガ計算
	lda <PAD_TMP
	tay
	eor <PAD_OLD
	and <PAD_TMP
	sta <PAD_TRG
	sty <PAD_OLD
	sty <PAD_ON
	rts

PadReadOnce:
	lda #$01
	sta $4016
	lda #$00
	sta $4016
	ldx #8
.rd
	lda $4016
	lsr a
	rol <PAD_TMP
	dex
	bne .rd
	rts

;------------------------------------------------------------------------------
; 乱数 (8bit LFSR)
;------------------------------------------------------------------------------
RngStep:
	lda <RNG
	asl a
	bcc .noeor
	eor #$1D
.noeor
	sta <RNG
	bne .ok
	lda #1			; 0になったら再シード
	sta <RNG
.ok
	rts

;------------------------------------------------------------------------------
; スプライトシャドウ初期化 (全部画面外へ)
;------------------------------------------------------------------------------
SpriteInit:
	lda #$FF
	ldx #0
.loop
	sta OAM_BUF,x		; Y=$FF で画面外
	inx
	inx
	inx
	inx
	bne .loop
	rts

;------------------------------------------------------------------------------
; 16x16スプライト設定
;  IN A:スプライト番号(先頭)  X:x座標  Y:y座標  T0:タイル左上
;     T1:属性(上段)  T4:属性(下段)
;------------------------------------------------------------------------------
SetSprite16:
	stx <T2			; x退避
	sty <T3			; y退避
	asl a
	asl a
	tax			; X = OAMオフセット
	; 左上
	lda <T3
	sta OAM_BUF,x
	lda <T0
	sta OAM_BUF+1,x
	lda <T1
	sta OAM_BUF+2,x
	lda <T2
	sta OAM_BUF+3,x
	; 右上
	lda <T3
	sta OAM_BUF+4,x
	lda <T0
	clc
	adc #1
	sta OAM_BUF+5,x
	lda <T1
	sta OAM_BUF+6,x
	lda <T2
	clc
	adc #8
	sta OAM_BUF+7,x
	; 左下
	lda <T3
	clc
	adc #8
	sta OAM_BUF+8,x
	lda <T0
	clc
	adc #$10
	sta OAM_BUF+9,x
	lda <T4
	sta OAM_BUF+10,x
	lda <T2
	sta OAM_BUF+11,x
	; 右下
	lda <T3
	clc
	adc #8
	sta OAM_BUF+12,x
	lda <T0
	clc
	adc #$11
	sta OAM_BUF+13,x
	lda <T4
	sta OAM_BUF+14,x
	lda <T2
	clc
	adc #8
	sta OAM_BUF+15,x
	rts

;------------------------------------------------------------------------------
; 16x16スプライトを隠す IN A:スプライト番号(先頭)
;------------------------------------------------------------------------------
HideSprite16:
	asl a
	asl a
	tax
	lda #$FF
	sta OAM_BUF,x
	sta OAM_BUF+4,x
	sta OAM_BUF+8,x
	sta OAM_BUF+12,x
	rts

;------------------------------------------------------------------------------
; スコア加算  IN A:加算値(0-9)  X:桁位置(0=1の位)
;------------------------------------------------------------------------------
ScoreAdd:
	clc
	adc <SCORE,x
.carry
	cmp #10
	bcc .store
	sec
	sbc #10
	sta <SCORE,x
	inx
	cpx #6
	bcs .done		; 桁あふれは無視
	lda <SCORE,x
	clc
	adc #1
	jmp .carry
.store
	sta <SCORE,x
.done
	lda #1
	sta <SCORE_DIRTY
	rts

;------------------------------------------------------------------------------
; スコア表示 (スプライト12枚: 6桁 x 上下)
;   スプライト番号5〜16を使用, 位置(200,20)から左へ
;------------------------------------------------------------------------------
DrawScore:
	ldx #0			; 桁
	lda #5
	asl a
	asl a
	tay			; OAMオフセット
	lda #200
	sta <T4			; x座標
	; 属性: ハイスコア更新中は金色(パレット3)
	lda #%00000010
	clc
	adc <GOLDSCORE
	sta <T5
.digit
	lda <SCORE,x
	clc
	adc #$C0		; 数字タイル
	sta <T2
	; 上半分
	lda #20
	sta OAM_BUF,y
	lda <T2
	sta OAM_BUF+1,y
	lda <T5
	sta OAM_BUF+2,y
	lda <T4
	sta OAM_BUF+3,y
	; 下半分
	lda #28
	sta OAM_BUF+4,y
	lda <T2
	clc
	adc #$10
	sta OAM_BUF+5,y
	lda <T5
	sta OAM_BUF+6,y
	lda <T4
	sta OAM_BUF+7,y
	; 次の桁 (左へ9px)
	tya
	clc
	adc #8
	tay
	lda <T4
	sec
	sbc #9
	sta <T4
	inx
	cpx #6
	bne .digit
	lda #0
	sta <SCORE_DIRTY
	rts

;------------------------------------------------------------------------------
; テキストをVRAMへ直接描画 (描画OFF時専用)
;  IN PTR_L/H:文字列(';'終端, ASCII)  T4:BG列(0-31)  T5:BG行(0-29)
;------------------------------------------------------------------------------
TextPrint:
	; アドレス計算: $2000 + y*32 + x
	lda <T5
	lsr a
	lsr a
	lsr a			; y/8
	clc
	adc #$20
	sta PPUADDR
	lda <T5
	asl a
	asl a
	asl a
	asl a
	asl a			; y*32 (下位)
	clc
	adc <T4
	sta PPUADDR
	ldy #0
.loop
	lda [PTR_L],y
	cmp #';'
	beq .done
	cmp #' '
	bne .chr
	lda #TILE_SKY		; 空白は空タイル
	jmp .put
.chr
	clc
	adc #STR2CHR
.put
	sta PPUDATA
	iny
	bne .loop
.done
	rts

;------------------------------------------------------------------------------
; パレット一括ロード (シャドウへ; 転送はNMI)
;  IN PTR_L/H: 32byteパレットデータ
;------------------------------------------------------------------------------
PalLoad:
	ldy #0
.loop
	lda [PTR_L],y
	sta PAL_BUF,y
	iny
	cpy #32
	bne .loop
	lda PAL_BUF		; $3F10ミラー対策
	sta PAL_BUF+16
	lda #1
	sta <PAL_DIRTY
	rts

;------------------------------------------------------------------------------
; キャラクタ用スプライトパレット設定 (PAL_BUF+16〜へ)
;   pal0=キャラ上段, pal1=キャラ下段, pal2=UI白, pal3=アイテム
;  IN A: キャラ番号(0-4)
;------------------------------------------------------------------------------
SetCharaPal:
	asl a
	asl a
	asl a
	asl a			; x16
	tax
	; pal0 <- テーブル行0
	ldy #0
.p0
	lda CharaPalTbl,x
	sta PAL_BUF+16,y
	inx
	iny
	cpy #4
	bne .p0
	; pal1 <- テーブル行2
	inx
	inx
	inx
	inx			; 行1を飛ばす
	ldy #0
.p1
	lda CharaPalTbl,x
	sta PAL_BUF+20,y
	inx
	iny
	cpy #4
	bne .p1
	; pal2 = UI (白)
	lda #$21
	sta PAL_BUF+24
	lda #$20
	sta PAL_BUF+25
	lda #$0F
	sta PAL_BUF+26
	lda #$17
	sta PAL_BUF+27
	; pal3 = アイテム (金/赤/緑)
	lda #$21
	sta PAL_BUF+28
	lda #$28
	sta PAL_BUF+29
	lda #$16
	sta PAL_BUF+30
	lda #$2A
	sta PAL_BUF+31
	; $3F10は$3F00のミラーなので空色と同期させる (空が上書きされるのを防ぐ)
	lda PAL_BUF
	sta PAL_BUF+16
	lda #1
	sta <PAL_DIRTY
	rts

;==============================================================================
; ステージ生成
;==============================================================================
;------------------------------------------------------------------------------
; 1列分のタイル生成
;  IN T0:列(0-63)  T1:土管あり?  T2:ゲート上端行  T3:土管内列位置(0-3)
;  OUT COLBUF[0..29]
;------------------------------------------------------------------------------
ColMake:
	ldx #0			; 行
.row
	lda <T1
	beq .empty
	; ----- 土管列 -----
	cpx #26
	bcs .ground
	; r と ゲートの関係
	txa
	clc
	adc #2
	cmp <T2			; r+2 < gap → 上部本体 (r < gap-2)
	bcc .body
	txa
	clc
	adc #2
	cmp <T2
	beq .captop		; r == gap-2
	txa
	clc
	adc #1
	cmp <T2
	beq .capbot		; r == gap-1
	txa
	cmp <T2
	bcc .body		; ここには来ないが保険
	; r >= gap
	sec
	sbc <T2			; A = r - gap
	cmp <GAPSZ_TMP
	bcc .sky		; ゲート内
	beq .captop		; r == gap+幅
	sbc <GAPSZ_TMP		; (carry set) A = r - gap - 幅
	cmp #1
	beq .capbot		; r == gap+幅+1
.body
	lda #$60
	clc
	adc <T3
	jmp .put
.captop
	lda #$40
	clc
	adc <T3
	jmp .put
.capbot
	lda #$50
	clc
	adc <T3
	jmp .put
.sky
	lda #TILE_SKY
	jmp .put
	; ----- 空列 -----
.empty
	cpx #22
	bcc .sky
	cpx #26
	bcs .ground
	; 背景ストリップ (雲/ビル/草) 行22-25
	txa
	sec
	sbc #22			; 0-3
	asl a
	asl a
	asl a
	asl a			; x16
	clc
	adc #$70
	sta <T6
	lda <T0
	and #$03
	clc
	adc <T6
	jmp .put
.ground
	cpx #28
	bcs .under
	lda #$F0		; 地面
	jmp .put
.under
	lda #$AC		; 地下ブロック
.put
	sta COLBUF,x
	inx
	cpx #30
	beq .rdone
	jmp .row
.rdone
	rts

;------------------------------------------------------------------------------
; COLBUFの行0-29をVRAMへ直接書き込み (描画OFF時専用)
;  IN T0:列(0-63)
;------------------------------------------------------------------------------
ColWriteDirect:
	lda #%10001100		; +32モード
	sta PPUCTRL
	; アドレス: $2000 + (col>=32? $400:0) + col&31
	lda <T0
	and #$20
	lsr a
	lsr a
	lsr a			; $20 -> $04
	clc
	adc #$20
	sta PPUADDR
	lda <T0
	and #$1F
	sta PPUADDR
	ldx #0
.loop
	lda COLBUF,x
	sta PPUDATA
	inx
	cpx #30
	bne .loop
	rts

;------------------------------------------------------------------------------
; COLBUFの行T4〜T5をVRAMバッファへ縦書きエントリとして追加
;  IN T0:列(0-63)  T4:開始行  T5:終了行(含む)
;------------------------------------------------------------------------------
ColToBuf:
	ldx <BUF_LEN
	; len
	lda <T5
	sec
	sbc <T4
	clc
	adc #1
	sta VBUF,x
	sta <T6			; 残数
	inx
	; addrH = $80(縦) | $20 | NT | (row>>3)
	lda <T0
	and #$20
	lsr a
	lsr a
	lsr a
	sta <T7
	lda <T4
	lsr a
	lsr a
	lsr a
	clc
	adc <T7
	clc
	adc #$20
	ora #$80
	sta VBUF,x
	inx
	; addrL = (row&7)<<5 | col&31
	lda <T4
	and #$07
	asl a
	asl a
	asl a
	asl a
	asl a
	sta <T7
	lda <T0
	and #$1F
	ora <T7
	sta VBUF,x
	inx
	; データ
	ldy <T4
.loop
	lda COLBUF,y
	sta VBUF,x
	inx
	iny
	dec <T6
	bne .loop
	; 終端マーク
	lda #0
	sta VBUF,x
	stx <BUF_LEN
	rts

;------------------------------------------------------------------------------
; 土管スロット描画 (直接書き込み版: 描画OFF時)
;  IN X:スロット(0-3)
;------------------------------------------------------------------------------
PipeSlotDrawDirect:
	stx <T7
	lda #0
	sta <T3			; 列位置j
.col
	lda <T7
	asl a
	asl a
	asl a
	asl a			; スロットx16
	clc
	adc <T3
	sta <T0			; 列番号
	ldx <T7
	lda PIPE_ACT,x
	sta <T1
	lda PIPE_GAP,x
	sta <T2
	lda PIPE_GAPSZ,x
	sta <GAPSZ_TMP
	jsr ColMake
	jsr ColWriteDirect
	inc <T3
	lda <T3
	cmp #4
	bne .col
	rts

;------------------------------------------------------------------------------
; 土管スロット再描画 (バッファ版: プレイ中)
;  IN X:スロット(0-3)  T4:開始行  T5:終了行
;------------------------------------------------------------------------------
PipeSlotDrawBuf:
	stx <SLOT_TMP
	lda <DRAW_C0
	sta <T3
.col
	lda <SLOT_TMP
	asl a
	asl a
	asl a
	asl a
	clc
	adc <T3
	sta <T0
	ldx <SLOT_TMP
	lda PIPE_ACT,x
	sta <T1
	lda PIPE_GAP,x
	sta <T2
	lda PIPE_GAPSZ,x
	sta <GAPSZ_TMP
	jsr ColMake
	jsr ColToBuf
	lda <T3
	cmp <DRAW_C1
	beq .colsdone
	inc <T3
	jmp .col
.colsdone
	; 属性書き込み: 列2フェーズ=属性行0-2, 列3フェーズ=属性行3-5
	lda <DRAW_C1
	cmp #2
	bne .chk3
	lda #0
	sta <T4
	lda #2
	sta <T5
	jsr PipeAttrRows
	jmp .noattr
.chk3
	cmp #3
	bne .noattr
	lda #3
	sta <T4
	lda #5
	sta <T5
	jsr PipeAttrRows
.noattr
	ldx <SLOT_TMP
	lda #1
	sta <BUF_READY
	rts

;------------------------------------------------------------------------------
; 土管セルの属性バイト書き込み (属性行T4..T5)
;   行0-4: ボス=$55(金) それ以外=$00 / 行5: ボス=$55 土管=$00 空=$A0
;------------------------------------------------------------------------------
PipeAttrRows:
	ldy <SLOT_TMP
.arow
	ldx <BUF_LEN
	lda #1
	sta VBUF,x
	inx
	lda PipeAttrHi,y
	sta VBUF,x
	inx
	; addrL = $C0 + 属性行*8 + セル
	lda <T4
	asl a
	asl a
	asl a
	clc
	adc #$C0
	clc
	adc PipeAttrCell,y
	sta VBUF,x
	inx
	; 値
	lda PIPE_BOSS,y
	beq .notboss
	lda #%01010101		; 金 (パレット1)
	jmp .aput
.notboss
	lda <T4
	cmp #5
	bne .apal0
	lda PIPE_ACT,y
	bne .apal0
	lda #%10100000		; 空スロットの行5は雲パレット
	jmp .aput
.apal0
	lda #%00000000
.aput
	sta VBUF,x
	inx
	lda #0
	sta VBUF,x
	stx <BUF_LEN
	inc <T4
	lda <T4
	cmp <T5
	bcc .arow
	beq .arow
	rts

;------------------------------------------------------------------------------
; ステージ全体構築 (描画OFF時)
;------------------------------------------------------------------------------
StageBuild:
	; 全64列を空で敷き詰め
	lda #0
	sta <T0
.cols
	lda #0
	sta <T1
	jsr ColMake
	jsr ColWriteDirect
	inc <T0
	lda <T0
	cmp #64
	bne .cols

	; 属性テーブル (両ネームテーブル)
	lda #$23
	jsr StageAttr
	lda #$27
	jsr StageAttr

	; 土管スロット初期化: 0,1=なし  2,3=あり
	ldx #3
.slotinit
	lda #0
	sta PIPE_ACT,x
	sta PIPE_MOV,x
	sta PIPE_PASS,x
	sta PIPE_RECYC,x
	sta PIPE_MOVPH,x
	sta PIPE_BOSS,x
	lda #GAP_ROWS
	sta PIPE_GAPSZ,x
	lda #1
	sta PIPE_DIR,x
	lda #8
	sta PIPE_GAP,x
	txa
	asl a
	asl a
	adc #MOVE_PERIOD
	sta PIPE_CNT,x		; 位相をずらす
	dex
	bpl .slotinit
	; スロット2,3に土管
	ldx #2
	jsr PipeNewGap
	lda #1
	sta PIPE_ACT+2
	ldx #3
	jsr PipeNewGap
	lda #1
	sta PIPE_ACT+3
	ldx #2
	jsr PipeSlotDrawDirect
	ldx #3
	jsr PipeSlotDrawDirect
	; 初期土管の属性 (行20-23をpal0へ)
	lda #%10001000		; +1モード
	sta PPUCTRL
	lda #$27
	sta PPUADDR
	lda #$E8
	sta PPUADDR
	lda #%00000000
	sta PPUDATA		; スロット2
	lda #$27
	sta PPUADDR
	lda #$EC
	sta PPUADDR
	lda #%00000000
	sta PPUDATA		; スロット3
	rts

;------------------------------------------------------------------------------
; 属性テーブル書き込み IN A:属性テーブル上位バイト($23/$27)
;------------------------------------------------------------------------------
StageAttr:
	sta PPUADDR
	lda #$C0
	sta PPUADDR
	lda #%10001000		; +1モード
	sta PPUCTRL
	; 行0-4: 空 (40byte)
	lda #%00000000
	ldx #40
.a0
	sta PPUDATA
	dex
	bne .a0
	; 行5: 上=空pal0 下=雲ビルpal2
	lda #%10100000
	ldx #8
.a1
	sta PPUDATA
	dex
	bne .a1
	; 行6: 上=草pal0 下=地面pal1
	lda #%01010000
	ldx #8
.a2
	sta PPUDATA
	dex
	bne .a2
	; 行7: 上=地下pal3
	lda #%00001111
	ldx #8
.a3
	sta PPUDATA
	dex
	bne .a3
	rts

;------------------------------------------------------------------------------
; 新しいゲート位置を乱数で決める IN X:スロット
;------------------------------------------------------------------------------
PipeNewGap:
	jsr RngStep
	lda <RNG
	and #$0F
	cmp #GAP_MAX-GAP_MIN+1
	bcc .ok
	sec
	sbc #GAP_MAX-GAP_MIN+1
	cmp #GAP_MAX-GAP_MIN+1
	bcc .ok
	lda #4			; 保険
.ok
	clc
	adc #GAP_MIN
	sta PIPE_GAP,x
	rts

;==============================================================================
; シーン: SHOKOロゴ
;==============================================================================
SceneLogo:
	lda <INITED
	bne .update
	; ---- 初期化 ----
	lda #0
	sta <PPU_ON
	sta PPUMASK
	sta <SCROLL_L
	sta <SCROLL_H
	sta <SCROLL_Y
	jsr SpriteInit
	; ロゴネームテーブル読み込み ($2000へ1KB)
	lda #%10001000		; +1モード
	sta PPUCTRL
	bit PPUSTAT
	lda #$20
	sta PPUADDR
	lda #$00
	sta PPUADDR
	lda #low(bglogo)
	sta <PTR_L
	lda #high(bglogo)
	sta <PTR_H
	ldx #4			; 4ページ
	ldy #0
.copy
	lda [PTR_L],y
	sta PPUDATA
	iny
	bne .copy
	inc <PTR_H
	dex
	bne .copy
	; パレット (シャドウ経由)
	lda #low(tilepal_logo)
	sta <PTR_L
	lda #high(tilepal_logo)
	sta <PTR_H
	jsr PalLoad
	; 背景色は黒に明示 (原作は$3F10ミラーの偶然で黒だった)
	lda #$0F
	sta PAL_BUF
	sta PAL_BUF+16
	lda #150
	sta <SCR_TIMER
	lda #1
	sta <INITED
	lda #2
	sta <PPU_ON		; 次のVBlankで描画ON
	rts
.update
	; A/START/SELECT または時間切れでタイトルへ
	lda <PAD_TRG
	and #PAD_A|PAD_ST|PAD_SL
	bne .next
	dec <SCR_TIMER
	bne .stay
.next
	lda #SC_TITLE
	jmp ChangeScene
.stay
	rts

;------------------------------------------------------------------------------
; シーン切り替え IN A:次のシーン
;------------------------------------------------------------------------------
ChangeScene:
	sta <SCENE
	lda #0
	sta <INITED
	rts

;==============================================================================
; シーン: タイトル
;==============================================================================
SceneTitle:
	lda <INITED
	beq .init
	jmp TitleUpdate
.init
	; ---- 初期化 ----
	lda #0
	sta <PPU_ON
	sta PPUMASK
	sta <SCROLL_L
	sta <SCROLL_H
	sta <SCROLL_Y
	sta <CURSOR
	sta <TITLE_MODE
	sta <IDLE_CNT
	jsr SpriteInit
	lda #%10001000		; +1モード
	sta PPUCTRL
	bit PPUSTAT
	; NT0 を空タイルで埋める
	lda #$20
	sta PPUADDR
	lda #$00
	sta PPUADDR
	lda #TILE_SKY
	ldx #$C0		; 960 = 4x256-64
	ldy #3
.fill1
	sta PPUDATA
	dex
	bne .fill1
.fill2
	sta PPUDATA
	dex
	bne .fill2
	dey
	bne .fill2
	; 属性: 全部パレット1
	lda #%01010101
	ldx #64
.attr
	sta PPUDATA
	dex
	bne .attr

	; タイトルロゴ (タイル$00-$3F, 16x4) を (8,6) に
	lda #0
	sta <T0			; タイル
	lda #6
	sta <T1			; 行
.logorow
	lda <T1
	lsr a
	lsr a
	lsr a
	clc
	adc #$20
	sta PPUADDR
	lda <T1
	asl a
	asl a
	asl a
	asl a
	asl a
	clc
	adc #8			; x=8
	sta PPUADDR
	ldx #16
	lda <T0
.logocol
	sta PPUDATA
	clc
	adc #1
	dex
	bne .logocol
	sta <T0
	inc <T1
	lda <T1
	cmp #10
	bne .logorow

	; メニューテキスト
	lda #low(StrGameStart)
	sta <PTR_L
	lda #high(StrGameStart)
	sta <PTR_H
	lda #11
	sta <T4
	lda #18			; 行18
	sta <T5
	jsr TextPrint
	lda #low(StrStaffRoll)
	sta <PTR_L
	lda #high(StrStaffRoll)
	sta <PTR_H
	lda #11
	sta <T4
	lda #20			; 行20
	sta <T5
	jsr TextPrint
	lda #low(StrAwards)
	sta <PTR_L
	lda #high(StrAwards)
	sta <PTR_H
	lda #11
	sta <T4
	lda #22			; 行22
	sta <T5
	jsr TextPrint
	lda #low(StrCharaHint)
	sta <PTR_L
	lda #high(StrCharaHint)
	sta <PTR_H
	lda #6
	sta <T4
	lda #24			; 行24
	sta <T5
	jsr TextPrint
	lda #low(StrCopyright)
	sta <PTR_L
	lda #high(StrCopyright)
	sta <PTR_H
	lda #6
	sta <T4
	lda #27			; 行27
	sta <T5
	jsr TextPrint

	; ハイスコア "HI" + 数字
	lda #low(StrHi)
	sta <PTR_L
	lda #high(StrHi)
	sta <PTR_H
	lda #10
	sta <T4
	lda #3			; 行3
	sta <T5
	jsr TextPrint
	; 数字6桁 (上位桁から)
	lda #$20
	sta PPUADDR
	lda #$6D		; 行3 x=13
	sta PPUADDR
	ldx #5
.hiscore
	lda <HISCORE,x
	clc
	adc #$C0
	sta PPUDATA
	dex
	bpl .hiscore

	; パレット
	lda #low(tilepal_logo)
	sta <PTR_L
	lda #high(tilepal_logo)
	sta <PTR_H
	jsr PalLoad
	; 背景色は水色に明示 (原作は$3F10ミラーの偶然で水色だった)
	lda #$21
	sta PAL_BUF
	lda <CHARA_NO
	jsr SetCharaPal		; スプライトパレット上書き(+16も同期される)

	; キャラプレビュー + カーソル
	jsr TitleDrawChara

	; BGM
	lda #MUS_TITLE
	jsr music_play

	lda #1
	sta <INITED
	lda #2
	sta <PPU_ON
	rts

TitleUpdate:
	lda <TITLE_MODE
	cmp #1
	bcc .mode0
	beq .jscroll
	jmp SecretRoom
.jscroll
	jmp SecretScroll
.mode0
	; ---- 放置検出 (約12秒で隠しページ発動) ----
	lda <PAD_ON
	beq .idlecnt
	lda #0
	sta <IDLE_CNT
	jmp .idledone
.idlecnt
	lda <FRAME_CNT
	and #$03
	bne .idledone
	inc <IDLE_CNT
	lda <IDLE_CNT
	cmp #180
	bne .idledone
	; 発動!
	lda #1
	sta <TITLE_MODE
	jsr SpriteInit
	lda #%01000000		; 実績: 隠しページ発見
	jsr AchSet
	lda #SE_STAR
	jsr sfx_play
	rts
.idledone
	; SELECT/上下: メニュー切り替え
	lda <PAD_TRG
	and #PAD_SL|PAD_UP|PAD_DN
	beq .nosel
	ldx <CURSOR
	inx
	cpx #3
	bne .curok
	ldx #0
.curok
	stx <CURSOR
.nosel
	; B: キャラ変更
	lda <PAD_TRG
	and #PAD_B
	beq .nochara
	ldx <CHARA_NO
	inx
	cpx #5
	bne .setchara
	ldx #0
.setchara
	stx <CHARA_NO
	lda <CHARA_NO
	jsr SetCharaPal
	lda #SE_SELECT
	jsr sfx_play
.nochara
	; カーソル/キャラ描画
	jsr TitleDrawChara

	; START/A: 決定
	lda <PAD_TRG
	and #PAD_ST|PAD_A
	beq .done
	lda #SE_SELECT
	jsr sfx_play
	lda <CURSOR
	bne .notgame
	lda #SC_GAME
	jmp ChangeScene
.notgame
	cmp #1
	bne .awards
	lda #SC_STAFF
	jmp ChangeScene
.awards
	lda #SC_AWARDS
	jmp ChangeScene
.done
	rts

; タイトルのキャラプレビューとカーソルを描く
TitleDrawChara:
	; キャラ (アニメつき)
	lda <CHARA_NO
	asl a
	asl a
	asl a
	asl a
	asl a			; x32
	clc
	adc #$20
	sta <T0
	lda <FRAME_CNT
	and #%00010000
	beq .noanim
	lda <T0
	ora #$02
	sta <T0
.noanim
	lda #%00000000
	sta <T1
	lda #%00000001
	sta <T4
	lda #0			; スプライト0
	ldx #40
	ldy #140
	jsr SetSprite16
	; カーソル (スプライト4)
	lda <CURSOR
	asl a
	asl a
	asl a
	asl a			; x16
	clc
	adc #143
	sta OAM_BUF+16		; y
	lda #$0B
	sta OAM_BUF+17		; tile
	lda #%00000010		; パレット2
	sta OAM_BUF+18
	lda #76
	sta OAM_BUF+19		; x
	rts

;------------------------------------------------------------------------------
; 隠しページ: 上スクロール演出
;   Yスクロールが8の倍数を跨ぐ直前に, 上端から消えた行へ隠しページの行を
;   書き込む → 下端から新しい内容が現れる (完全に連続な縦スクロール)
;------------------------------------------------------------------------------
SecretScroll:
	lda <SCROLL_Y
	clc
	adc #1
	and #$07
	bne .nowrite
	lda <SCROLL_Y
	lsr a
	lsr a
	lsr a			; 行番号 = S>>3
	jsr SecretRowWrite
.nowrite
	inc <SCROLL_Y
	lda <SCROLL_Y
	cmp #240
	bne .cont
	lda #0
	sta <SCROLL_Y
	lda #2
	sta <TITLE_MODE
.cont
	rts

;------------------------------------------------------------------------------
; 隠し部屋: START/Aでレインボースタート, Bでタイトルへ戻る
;------------------------------------------------------------------------------
SecretRoom:
	lda <PAD_TRG
	and #PAD_ST|PAD_A
	beq .nostart
	lda #1
	sta <SECRET_GIFT
	lda #SE_SELECT
	jsr sfx_play
	lda #SC_GAME
	jmp ChangeScene
.nostart
	lda <PAD_TRG
	and #PAD_B
	beq .stay
	lda #SC_TITLE
	jmp ChangeScene		; 再構築して通常タイトルへ
.stay
	rts

;------------------------------------------------------------------------------
; 隠しページの1行(32タイル)をバッファへ書く IN A:行(0-29)
;------------------------------------------------------------------------------
SecretRowWrite:
	sta <T3
	; テーブル参照 (行あたり3バイト: 文字列ptr, 開始列)
	asl a
	clc
	adc <T3			; x3
	tay
	lda SecretRowTbl,y
	sta <PTR_L
	lda SecretRowTbl+1,y
	sta <PTR_H
	lda SecretRowTbl+2,y
	sta <T4			; 開始列
	; エントリヘッダ
	ldx <BUF_LEN
	lda #32
	sta VBUF,x
	inx
	lda <T3
	lsr a
	lsr a
	lsr a
	clc
	adc #$20
	sta VBUF,x
	inx
	lda <T3
	and #$07
	asl a
	asl a
	asl a
	asl a
	asl a
	sta VBUF,x
	inx
	; 32列ぶん生成
	lda #0
	sta <T5			; 列
.col
	lda <PTR_H
	beq .blank		; 文字列なし
	lda <T5
	cmp <T4
	bcc .blank		; 開始列より前
	lda <T5
	sec
	sbc <T4
	tay
	lda [PTR_L],y
	cmp #';'
	bne .chr
	lda #0
	sta <PTR_H		; 終端: 以降は空
	jmp .blank
.chr
	cmp #' '
	bne .conv
	lda #TILE_SKY
	jmp .put
.conv
	clc
	adc #STR2CHR
	jmp .put
.blank
	lda #TILE_SKY
.put
	sta VBUF,x
	inx
	inc <T5
	lda <T5
	cmp #32
	beq .rowdone
	jmp .col
.rowdone
	lda #0
	sta VBUF,x
	stx <BUF_LEN
	lda #1
	sta <BUF_READY
	rts

;==============================================================================
; シーン: ゲーム本体
;==============================================================================
SceneGame:
	lda <INITED
	beq .init
	jmp GameUpdate
.init
	; ---- 初期化 ----
	lda #0
	sta <PPU_ON
	sta PPUMASK
	sta <SCROLL_L
	sta <SCROLL_H
	sta <SCROLL_Y
	sta <BUF_LEN
	sta VBUF
	sta <BUF_READY
	sta <STAR_TIMER
	jsr SpriteInit
	bit PPUSTAT

	; ステージ構築 (NT両面 + 属性 + 初期土管)
	jsr StageBuild

	; スコアクリア
	ldx #5
	lda #0
.sc
	sta <SCORE,x
	dex
	bpl .sc
	lda #1
	sta <SCORE_DIRTY

	; アイテムクリア
	lda #0
	sta ITEM_ACT
	sta ITEM_ACT+1

	; 鳥初期化
	lda #BIRD_Y_INIT
	sta <BIRD_Y
	lda #0
	sta <BIRD_YF
	sta <VEL_L
	sta <VEL_H
	sta <BIRD_ANIM
	lda #GS_WAIT
	sta <GAME_ST
	lda #0
	sta <SCROLL_F
	sta <SPEED_ADD
	sta <PALPHASE
	sta <PAUSED
	sta <NEWREC
	sta <GOLDSCORE
	sta <COMBO
	sta <WIND_DIR
	lda #100
	sta <WIND_TMR
	lda #0
	ldx #4
.pclr
	sta PART_LIFE,x
	dex
	bpl .pclr

	; パレット: ステージBG + キャラ/UI/アイテム スプライト
	ldx #0
.palbg
	lda PalStageBG,x
	sta PAL_BUF,x
	inx
	cpx #16
	bne .palbg
	lda <CHARA_NO
	jsr SetCharaPal		; PAL_DIRTYも立つ

	; BGM: 10曲からランダム選曲
	jsr RngStep
	lda <RNG
	and #$0F
	tax
	lda StageBgmTbl,x
	sta <STAGE_BGM
	jsr music_play

	; 隠しページからの開始: レインボースタート!
	lda <SECRET_GIFT
	beq .nogift
	lda #0
	sta <SECRET_GIFT
	lda #254
	sta <STAR_TIMER
	lda #MUS_STAR
	jsr music_play
.nogift

	lda #1
	sta <INITED
	lda #2
	sta <PPU_ON
	rts

;------------------------------------------------------------------------------
GameUpdate:
	; B: キャラ変更 (いつでも)
	lda <PAD_TRG
	and #PAD_B
	beq .nochara
	ldx <CHARA_NO
	inx
	cpx #5
	bne .setchara
	ldx #0
.setchara
	stx <CHARA_NO
	lda <CHARA_NO
	jsr SetCharaPal
.nochara
	jsr PartUpdate
	jsr PopUpdate

	lda <GAME_ST
	cmp #GS_WAIT
	beq GameWait
	cmp #GS_RUN
	beq GameRun
	jmp GameDead

;------------------------------------------------------------------------------
; 待機状態: 鳥はふわふわ, PUSH A 点滅
;------------------------------------------------------------------------------
GameWait:
	; ふわふわ
	lda <FRAME_CNT
	lsr a
	lsr a
	lsr a
	and #$07
	tax
	lda BobTbl,x
	clc
	adc #BIRD_Y_INIT-2
	sta <BIRD_Y

	; PUSH A 点滅表示
	lda <FRAME_CNT
	and #%00100000
	bne .hidepusha
	jsr DrawPushA
	jmp .pushadone
.hidepusha
	jsr HidePushA
.pushadone

	; A で開始
	lda <PAD_TRG
	and #PAD_A
	beq .noflap
	lda #GS_RUN
	sta <GAME_ST
	jsr HidePushA
	; 乱数に人間エントロピーを混ぜる
	lda <RNG
	eor <FRAME_CNT
	ora #1
	sta <RNG
	jsr BirdFlap
.noflap
	jsr BirdDraw
	jsr ItemsUpdate
	lda <SCORE_DIRTY
	beq .nodraw
	jsr DrawScore
	jsr DrawGauge
.nodraw
	rts

;------------------------------------------------------------------------------
; プレイ中
;------------------------------------------------------------------------------
GameRun:
	; START: ポーズ切り替え
	lda <PAD_TRG
	and #PAD_ST
	beq .nopause
	lda <PAUSED
	eor #$01
	sta <PAUSED
	lda #SE_SELECT
	jsr sfx_play
.nopause
	lda <PAUSED
	beq .go
	; ---- ポーズ中: 鳥を点滅させるだけ ----
	lda <FRAME_CNT
	and #$10
	bne .pblink
	jsr BirdDraw
	rts
.pblink
	lda #0
	jsr HideSprite16
	rts
.go
	; スクロール前進 (可変速: スコアで加速)
	jsr SpeedUpdate
	lda <SCROLL_F
	clc
	adc <SPEED_ADD
	sta <SCROLL_F
	lda <SCROLL_L
	adc #1
	sta <SCROLL_L
	bcc .noc
	lda <SCROLL_H
	eor #$01
	sta <SCROLL_H
.noc
	; パレット位相 (昼→夕→夜)
	jsr PalPhaseUpdate
	; 風の状態更新
	jsr WindUpdate
	; A: 羽ばたき
	lda <PAD_TRG
	and #PAD_A
	beq .noflap
	jsr BirdFlap
.noflap
	jsr BirdPhysics
	; 地面?
	lda <BIRD_Y
	cmp #GROUND_Y
	bcc .nofloor
	jmp BirdDie
.nofloor
	jsr PipesUpdate
	jsr ItemsUpdate
	jsr CollisionCheck
	; スター無敵タイマー (切れたら元のBGMに復帰)
	lda <STAR_TIMER
	beq .nostar
	dec <STAR_TIMER
	bne .nostar
	lda <STAGE_BGM
	jsr music_play
.nostar
	jsr BirdDraw
	lda <SCORE_DIRTY
	beq .nodraw
	jsr ChkGold
	jsr AchScoreCheck
	jsr DrawScore
	jsr DrawGauge
.nodraw
	rts

;------------------------------------------------------------------------------
; ハイスコア更新中か? → GOLDSCORE (スコア表示が金色になる)
;------------------------------------------------------------------------------
ChkGold:
	ldx #5
.cmp
	lda <SCORE,x
	cmp <HISCORE,x
	bcc .no
	bne .yes
	dex
	bpl .cmp
.no
	lda #0
	sta <GOLDSCORE
	rts
.yes
	lda #1
	sta <GOLDSCORE
	rts

;------------------------------------------------------------------------------
; 実績セット IN A:ビットマスク (新規解除ならファンファーレ)
;------------------------------------------------------------------------------
AchSet:
	sta <T6
	and ACH_FLAGS
	bne .already		; 既に解除済み
	lda ACH_FLAGS
	ora <T6
	sta ACH_FLAGS
	lda #SE_FANFARE
	jsr sfx_play
.already
	rts

;------------------------------------------------------------------------------
; スコア系実績チェック (SCORE_DIRTY時に呼ぶ)
;------------------------------------------------------------------------------
AchScoreCheck:
	ldy #0
	lda #1
	jsr ScoreGE
	bcc .done
	lda #%00000001		; FIRST FLIGHT
	jsr AchSet
	ldy #0
	lda #5
	jsr ScoreGE
	bcc .done
	lda #%00000010		; ランク2 (5点)
	jsr AchSet
	ldy #5
	lda #0
	jsr ScoreGE
	bcc .done
	lda #%00000100		; ランク4 (50点)
	jsr AchSet
	ldy #10
	lda #0
	jsr ScoreGE
	bcc .done
	lda #%00001000		; ランク5 (100点)
	jsr AchSet
.done
	rts

;------------------------------------------------------------------------------
; スコアがしきい値以上か IN Y:十の位 A:一の位 OUT C=1:以上
;------------------------------------------------------------------------------
ScoreGE:
	sta <T6
	sty <T7
	lda <SCORE+2
	ora <SCORE+3
	ora <SCORE+4
	ora <SCORE+5
	bne .ge
	lda <SCORE+1
	cmp <T7
	bcc .lt
	bne .ge
	lda <SCORE
	cmp <T6
	bcc .lt
.ge
	sec
	rts
.lt
	clc
	rts

;------------------------------------------------------------------------------
; ランクゲージ描画 (無限ランク制)
;   必要スコア: ランクnに上がるには累積 n*(n+1) 点 (2,6,12,20,30,...)
;   スプライト35,36=ランク数字(8x8小数字2桁) 37-40=進捗バー4セル
;------------------------------------------------------------------------------
BIN_L	.equ	$0C
BIN_H	.equ	$0D

DrawGauge:
	; ---- スコア→バイナリ (999でクランプ) ----
	lda <SCORE+3
	ora <SCORE+4
	ora <SCORE+5
	beq .conv
	lda #$E7		; 999
	sta <BIN_L
	lda #$03
	sta <BIN_H
	jmp .rank
.conv
	lda <SCORE		; 一の位
	sta <BIN_L
	lda #0
	sta <BIN_H
	; +十の位*10
	ldx <SCORE+1
	beq .h100
.t10
	lda <BIN_L
	clc
	adc #10
	sta <BIN_L
	bcc .t10n
	inc <BIN_H
.t10n
	dex
	bne .t10
.h100
	; +百の位*100
	ldx <SCORE+2
	beq .rank
.t100
	lda <BIN_L
	clc
	adc #100
	sta <BIN_L
	bcc .t100n
	inc <BIN_H
.t100n
	dex
	bne .t100
.rank
	; ---- ランク計算: t=0 step=2; bin>=t+step の間 昇格 ----
	lda #0
	sta <T0			; t lo
	sta <T1			; t hi
	sta <T3			; ランク(0基点)
	lda #2
	sta <T2			; step
.rloop
	; T4/T5 = t + step
	lda <T0
	clc
	adc <T2
	sta <T4
	lda <T1
	adc #0
	sta <T5
	; bin >= T4/T5 ?
	lda <BIN_H
	cmp <T5
	bcc .rdone
	bne .rup
	lda <BIN_L
	cmp <T4
	bcc .rdone
.rup
	lda <T4
	sta <T0
	lda <T5
	sta <T1
	lda <T2
	clc
	adc #2
	sta <T2
	inc <T3
	lda <T3
	cmp #98
	bcc .rloop
.rdone
	; ---- 進捗 = bin - t (8bitで十分) ----
	lda <BIN_L
	sec
	sbc <T0
	sta <T4			; progress
	; quarter = step/4
	lda <T2
	lsr a
	lsr a
	sta <T5
	bne .qok
	lda #1
	sta <T5			; 最低1
.qok
	; ---- ランク数字 (T3+1 を2桁で) ----
	ldx <T3
	inx			; 表示ランク = T3+1
	txa
	ldy #0
.div10
	cmp #10
	bcc .divd
	sec
	sbc #10
	iny
	jmp .div10
.divd
	sta <T6			; 一の位
	sty <T7			; 十の位
	; スプライト35 (十の位, 0なら非表示)
	ldx #140		; 35*4
	lda <T7
	bne .tens
	lda #$FF
	sta OAM_BUF,x
	jmp .ones
.tens
	lda #12
	sta OAM_BUF,x
	lda <T7
	sta OAM_BUF+1,x		; 小数字タイル$00-$09
	lda #%00000010
	sta OAM_BUF+2,x
	lda #8
	sta OAM_BUF+3,x
.ones
	; スプライト36 (一の位)
	ldx #144
	lda #12
	sta OAM_BUF,x
	lda <T6
	sta OAM_BUF+1,x
	lda #%00000010
	sta OAM_BUF+2,x
	lda #16
	sta OAM_BUF+3,x
	; ---- バー4セル (スプライト37-40) ----
	lda #0
	sta <T6			; セル番号 0-3
.cell
	; しきい値 = quarter*(セル+1)
	ldx <T6
	inx
	lda #0
.qmul
	clc
	adc <T5
	dex
	bne .qmul
	; progress >= しきい値 ?
	cmp <T4
	bcc .full
	beq .full
	lda #$FF		; 空セル
	jmp .ctile
.full
	lda #$FE		; 満セル
.ctile
	pha
	lda <T6
	clc
	adc #37
	asl a
	asl a
	tax
	lda #12
	sta OAM_BUF,x
	pla
	sta OAM_BUF+1,x
	lda #%00000011
	sta OAM_BUF+2,x
	lda <T6
	asl a
	asl a
	asl a
	clc
	adc #28
	sta OAM_BUF+3,x
	inc <T6
	lda <T6
	cmp #4
	bne .cell
	rts

;------------------------------------------------------------------------------
; 死亡後の落下
;------------------------------------------------------------------------------
GameDead:
	jsr BirdPhysics
	lda <BIRD_Y
	cmp #GROUND_Y+6
	bcc .fall
	lda #GROUND_Y+6
	sta <BIRD_Y
	jsr BirdDraw
	lda #SC_OVER
	jmp ChangeScene
.fall
	jsr BirdDraw
	rts

;------------------------------------------------------------------------------
; 羽ばたき
;------------------------------------------------------------------------------
BirdFlap:
	ldx <CHARA_NO
	lda CharFlapLo,x
	sta <VEL_L
	lda CharFlapHi,x
	sta <VEL_H
	lda #SE_FLAP
	jsr sfx_play
	lda #8
	sta <FLAP_HOLD
	; 星をパッと散らす
	lda #BIRD_X-3
	sta <T0
	lda <BIRD_Y
	clc
	adc #8
	sta <T1
	lda #3
	jsr PartSpawn
	rts

;------------------------------------------------------------------------------
; 鳥の物理 (重力・速度・座標)
;------------------------------------------------------------------------------
BirdPhysics:
	; vel += 重力 (キャラ別)
	ldx <CHARA_NO
	lda <VEL_L
	clc
	adc CharGravity,x
	sta <VEL_L
	lda <VEL_H
	adc #0
	sta <VEL_H
	; 風の影響 (プレイ中のみ, やさしめ)
	lda <GAME_ST
	cmp #GS_RUN
	bne .nowind
	lda <WIND_DIR
	beq .nowind
	bmi .winddn
	; 上昇気流: vel -= $0E (やさしめ)
	lda <VEL_L
	sec
	sbc #$0E
	sta <VEL_L
	lda <VEL_H
	sbc #0
	sta <VEL_H
	jmp .nowind
.winddn
	; 下降気流: vel += $0E
	lda <VEL_L
	clc
	adc #$0E
	sta <VEL_L
	lda <VEL_H
	adc #0
	sta <VEL_H
.nowind
	; 最大落下速度
	bmi .noclamp		; 上昇中はそのまま
	cmp #MAXFALL_HI
	bcc .noclamp
	lda #MAXFALL_HI
	sta <VEL_H
	lda #0
	sta <VEL_L
.noclamp
	; Y += vel
	lda <BIRD_YF
	clc
	adc <VEL_L
	sta <BIRD_YF
	lda <BIRD_Y
	adc <VEL_H
	sta <BIRD_Y
	; 天井
	cmp #240
	bcs .ceil		; 負に回り込んだ
	cmp #8
	bcs .ok
.ceil
	lda #8
	sta <BIRD_Y
	lda #0
	sta <VEL_L
	sta <VEL_H
.ok
	rts

;------------------------------------------------------------------------------
; 鳥の描画
;------------------------------------------------------------------------------
BirdDraw:
	; ベースタイル = $20 + キャラ番号*$20
	lda <CHARA_NO
	asl a
	asl a
	asl a
	asl a
	asl a
	clc
	adc #$20
	sta <T0
	; 死亡中はパニックばたばた
	lda <GAME_ST
	cmp #GS_DEAD
	bne .alive
	lda <FRAME_CNT
	and #$04
	beq .pd
	lda <T0
	ora #$02
	sta <T0
.pd
	lda <T0
	ora #$04		; 上向きポーズで慌てる
	sta <T0
	jmp .attr
.alive
	; 羽ばたきアニメ
	lda <FLAP_HOLD
	beq .noanim
	dec <FLAP_HOLD
	lda <T0
	ora #$02		; 羽上げフレーム
	sta <T0
	jmp .pose
.noanim
	lda <FRAME_CNT
	and #%00010000
	beq .pose
	lda <T0
	ora #$02
	sta <T0
.pose
	; 上昇中は上向きポーズ
	lda <VEL_H
	bpl .attr
	lda <T0
	ora #$04
	sta <T0
.attr
	; 属性 (スター中は点滅でパレット切り替え)
	lda <STAR_TIMER
	beq .normal
	lda <FRAME_CNT
	and #%00000100
	beq .normal
	lda #%00000010
	sta <T1
	lda #%00000011
	sta <T4
	jmp .draw
.normal
	lda #%00000000
	sta <T1
	lda #%00000001
	sta <T4
.draw
	lda #0			; スプライト0
	ldx #BIRD_X
	ldy <BIRD_Y
	jsr SetSprite16
	rts

;------------------------------------------------------------------------------
; 死亡処理
;------------------------------------------------------------------------------
BirdDie:
	lda #GS_DEAD
	sta <GAME_ST
	lda #0
	sta <COMBO
	jsr music_stop
	lda #SE_HIT
	jsr sfx_play
	; 小さく跳ねてから落ちる
	lda #$00
	sta <VEL_L
	lda #$FE
	sta <VEL_H
	rts

;------------------------------------------------------------------------------
; PUSH A 表示 (スプライト17-21, タイル$E0-$E4)
;------------------------------------------------------------------------------
DrawPushA:
	ldx #0
	lda #17
	asl a
	asl a
	tay
	lda #44
	sta <T4
.loop
	lda #80
	sta OAM_BUF,y
	txa
	clc
	adc #$E0
	sta OAM_BUF+1,y
	lda #%00000010
	sta OAM_BUF+2,y
	lda <T4
	sta OAM_BUF+3,y
	clc
	adc #8
	sta <T4
	tya
	clc
	adc #4
	tay
	inx
	cpx #5
	bne .loop
	rts

HidePushA:
	lda #17
	asl a
	asl a
	tax
	lda #$FF
	ldy #5
.loop
	sta OAM_BUF,x
	inx
	inx
	inx
	inx
	dey
	bne .loop
	rts

;------------------------------------------------------------------------------
; 土管スロット更新 (リサイクル + 上下移動)
;   VBlank予算対策: 再描画はすべて小分けにしてバッファ混雑時は延期する
;------------------------------------------------------------------------------
PipesUpdate:
	ldx #0
.slot
	; --- リサイクル描画フェーズ (1列/フレーム, RECYC=5..2 → 列0..3) ---
	lda PIPE_RECYC,x
	cmp #2
	bcc .zonechk		; 0 or 1
	lda <BUF_LEN
	cmp #50
	bcs .move		; 混雑: 次フレーム再試行
	lda #5
	sec
	sbc PIPE_RECYC,x	; 列番号 0-3
	sta <DRAW_C0
	sta <DRAW_C1		; 列3のときは属性も書かれる
	lda #0
	sta <T4
	lda #25
	sta <T5
	txa
	pha
	jsr PipeSlotDrawBuf
	pla
	tax
	dec PIPE_RECYC,x
	jmp .move
.zonechk
	; --- リサイクル開始判定: d = (scroll - slotX) & 511 が [40,71] ---
	lda <SCROLL_L
	sec
	sbc SlotXLo,x
	sta <T0
	lda <SCROLL_H
	sbc SlotXHi,x
	and #$01
	bne .outzone		; d >= 256
	lda <T0
	cmp #40
	bcc .outzone
	cmp #72
	bcs .outzone
	; ゾーン内
	lda PIPE_RECYC,x
	bne .move		; 既に開始/完了
	jsr PipeRecycle		; 抽選のみ (描画はフェーズで)
	jmp .move
.outzone
	lda #0
	sta PIPE_RECYC,x
.move
	; --- 上下移動 ---
	lda PIPE_ACT,x
	bne .mv1
	jmp .next
.mv1
	lda PIPE_MOV,x
	bne .mv2
	jmp .next
.mv2
	lda PIPE_RECYC,x
	cmp #2
	bcc .mv3
	jmp .next		; リサイクル描画中は動かさない
.mv3
	; 下側窓の残り描画があれば先に
	lda PIPE_MOVPH,x
	beq .mvtimer
	lda <BUF_LEN
	cmp #50
	bcs .jnext		; 混雑: 次フレーム
	; 下側窓: 行[gap+GAP-1, gap+GAP+2]
	lda PIPE_GAP,x
	clc
	adc #GAP_ROWS-1
	sta <T4
	lda PIPE_GAP,x
	clc
	adc #GAP_ROWS+2
	sta <T5
	lda #0
	sta <DRAW_C0
	lda #3
	sta <DRAW_C1
	txa
	pha
	jsr PipeSlotDrawBuf
	pla
	tax
	lda #0
	sta PIPE_MOVPH,x
	jmp .next
.jnext
	jmp .next
.mvtimer
	; 鳥が近い間は動かさない (接近16px手前〜通過完了まで)
	lda <SCROLL_L
	clc
	adc #BIRD_X+44
	sta <T0
	lda <SCROLL_H
	adc #0
	sta <T1
	lda <T0
	sec
	sbc SlotXLo,x
	sta <T0
	lda <T1
	sbc SlotXHi,x
	and #$01
	bne .movego		; 遠い
	lda <T0
	cmp #89
	bcs .movego
	jmp .next		; 接近中: 停止
.movego
	dec PIPE_CNT,x
	beq .cnt0
	jmp .next
.cnt0
	; 移動実行 (バッファ混雑時は1フレーム延期)
	lda <BUF_LEN
	cmp #50
	bcc .domove
	inc PIPE_CNT,x		; 次フレーム再試行
	jmp .next
.domove
	lda #MOVE_PERIOD
	sta PIPE_CNT,x
	; 端で方向反転
	lda PIPE_GAP,x
	cmp #GAP_MIN+1
	bcs .notmin
	lda #1
	sta PIPE_DIR,x
.notmin
	lda PIPE_GAP,x
	cmp #GAP_MAX
	bcc .notmax
	lda #$FF
	sta PIPE_DIR,x
.notmax
	lda PIPE_GAP,x
	clc
	adc PIPE_DIR,x
	sta PIPE_GAP,x
	; 上側窓のみ今フレーム描画: 行[gap-3, gap]
	sec
	sbc #3
	sta <T4
	lda PIPE_GAP,x
	sta <T5
	lda #0
	sta <DRAW_C0
	lda #3
	sta <DRAW_C1
	txa
	pha
	jsr PipeSlotDrawBuf
	pla
	tax
	lda #1
	sta PIPE_MOVPH,x	; 下側窓は次フレーム
.next
	inx
	cpx #4
	beq .done
	jmp .slot
.done
	rts

;------------------------------------------------------------------------------
; 土管再生成 IN X:スロット (X保存)
;------------------------------------------------------------------------------
PipeRecycle:
	lda #5
	sta PIPE_RECYC,x	; 描画フェーズ開始 (5..2で列0..3を1列ずつ)
	lda #1
	sta PIPE_ACT,x
	lda #0
	sta PIPE_PASS,x
	sta PIPE_MOVPH,x
	jsr PipeNewGap
	; ボス抽選: スコア15以上で 1/8 (金色/狭ゲート/+3点/移動なし)
	lda #0
	sta PIPE_BOSS,x
	lda #GAP_ROWS
	sta PIPE_GAPSZ,x
	ldy #1
	lda #5
	jsr ScoreGE
	bcc .noboss
	jsr RngStep
	lda <RNG
	and #$07
	bne .noboss
	lda #1
	sta PIPE_BOSS,x
	lda #GAP_ROWS-2
	sta PIPE_GAPSZ,x
	lda #0
	sta PIPE_MOV,x
	jmp .nomove		; ボスは移動しない
.noboss
	; スコア10以上なら 1/2 の確率で移動土管に
	lda #0
	sta PIPE_MOV,x
	lda <SCORE+1
	ora <SCORE+2
	ora <SCORE+3
	beq .nomove
	jsr RngStep
	lda <RNG
	and #$01
	beq .nomove
	lda #1
	sta PIPE_MOV,x
	lda #MOVE_PERIOD
	sta PIPE_CNT,x
	jsr RngStep
	lda <RNG
	and #$02
	beq .dirdown
	lda #$FF
	sta PIPE_DIR,x
	jmp .nomove
.dirdown
	lda #1
	sta PIPE_DIR,x
.nomove
	; アイテム出現 (75%)
	jsr RngStep
	lda <RNG
	and #$03
	cmp #$03
	beq .noitem
	jsr ItemSpawn
.noitem
	rts

;------------------------------------------------------------------------------
; アイテム出現 IN X:土管スロット (X保存)
;------------------------------------------------------------------------------
ItemSpawn:
	; 空きアイテムスロット探し
	ldy #0
	lda ITEM_ACT
	beq .found
	ldy #1
	lda ITEM_ACT+1
	beq .found
	rts			; 空きなし
.found
	; X座標 = スロットX + 64 (次の土管との中間)
	lda SlotXLo,x
	clc
	adc #64
	sta ITEM_XL,y
	lda SlotXHi,x
	adc #0
	and #$01
	sta ITEM_XH,y
	; Y座標 = 48 + (rng&127), 150超なら-80
	jsr RngStep
	lda <RNG
	and #$7F
	clc
	adc #48
	cmp #150
	bcc .yok
	sec
	sbc #80
.yok
	sta ITEM_Y,y
	; 種類: 0-8=コイン(0) 9-12=チェリー(2) 13-15=スター(1)
	jsr RngStep
	lda <RNG
	and #$0F
	cmp #9
	bcc .coin
	cmp #13
	bcc .cherry
	lda #1			; スター
	jmp .settype
.cherry
	lda #2
	jmp .settype
.coin
	lda #0
.settype
	sta ITEM_TYPE,y
	lda #0
	sta ITEM_ARM,y
	lda #1
	sta ITEM_ACT,y
	rts

;------------------------------------------------------------------------------
; アイテム更新・描画・取得判定
;------------------------------------------------------------------------------
ItemsUpdate:
	lda #0
	sta <ITEM_IDX
.item
	ldy <ITEM_IDX
	lda ITEM_ACT,y
	bne .active
	jmp .hide
.active
	; 画面X = (X - scroll) & 511
	lda ITEM_XL,y
	sec
	sbc <SCROLL_L
	sta <T5			; 画面x
	lda ITEM_XH,y
	sbc <SCROLL_H
	and #$01
	beq .onscreen
	; 画面外(右側): まだ未入場ならアーム
	lda #1
	sta ITEM_ARM,y
	jmp .hide
.onscreen
	; 画面内相当でも未入場なら表示しない (生成直後の左端出現防止)
	lda ITEM_ARM,y
	bne .armed
	jmp .hide
.armed
	; 左に流れ去ったら消す (画面左端16px以内)
	lda <T5
	cmp #16
	bcs .visible
	lda #0
	sta ITEM_ACT,y
	; コインを取り逃したらコンボ終了
	lda ITEM_TYPE,y
	bne .misok
	lda #0
	sta <COMBO
.misok
	jmp .hide
.visible
	; 取得判定: |sx - BIRD_X| < 13 && |iy - birdY| < 14
	lda <T5
	sec
	sbc #BIRD_X
	bcs .dxp
	eor #$FF
	clc
	adc #1
.dxp
	cmp #13
	bcc .dychk
	jmp .draw
.dychk
	lda ITEM_Y,y
	sec
	sbc <BIRD_Y
	bcs .dyp
	eor #$FF
	clc
	adc #1
.dyp
	cmp #14
	bcc .pickup
	jmp .draw
.pickup
	; ---- 取得! ----
	lda #0
	sta ITEM_ACT,y
	lda ITEM_TYPE,y
	pha			; 種類退避 (PartSpawnがX/Yを壊すため)
	lda <T5
	clc
	adc #4
	sta <T0
	lda ITEM_Y,y
	clc
	adc #4
	sta <T1
	lda #5
	jsr PartSpawn
	pla
	beq .getcoin
	cmp #1
	beq .getstar
	; チェリー: +20点
	lda #SE_ITEM
	jsr sfx_play
	ldx #0
	lda #2
	jsr PopSpawn
	lda #2
	ldx #1
	jsr ScoreAdd
	jmp .hide
.getcoin
	; コイン: コンボで価値上昇 (5/10/15/20点)
	lda <COMBO
	cmp #4
	bcs .cmax
	inc <COMBO
.cmax
	lda <COMBO
	cmp #4
	bcc .cse
	lda #%00010000		; 実績: コンボMAX
	jsr AchSet
	lda #SE_STAR		; 最大コンボはキラキラ音
	jsr sfx_play
	jmp .cadd
.cse
	lda #SE_ITEM
	jsr sfx_play
.cadd
	; 得点ポップ (T0/T1はアイテム位置のまま)
	ldy <COMBO
	ldx ComboOnes,y
	lda ComboTens,y
	jsr PopSpawn
	ldy <COMBO
	lda ComboOnes,y
	beq .cten
	ldx #0
	jsr ScoreAdd
.cten
	ldy <COMBO
	lda ComboTens,y
	beq .cdone
	ldx #1
	jsr ScoreAdd
.cdone
	jmp .hide
.getstar
	; スター: 無敵! 専用曲へ
	lda #SE_STAR
	jsr sfx_play
	lda #255
	sta <STAR_TIMER
	lda #%00100000		; 実績: スターライダー
	jsr AchSet
	lda #MUS_STAR
	jsr music_play
	jmp .hide
.draw
	; タイル決定
	lda ITEM_TYPE,y
	beq .tcoin
	cmp #1
	beq .tstar
	lda #$EC		; チェリー
	jmp .st
.tstar
	lda #$EA		; スター
	jmp .st
.tcoin
	lda <FRAME_CNT
	and #%00010000
	beq .c0
	lda #$E8		; コイン(横向き)
	jmp .st
.c0
	lda #$E6		; コイン(正面)
.st
	sta <T0
	lda #%00000011		; パレット3
	sta <T1
	sta <T4
	; SetSprite16呼び出し: A=22+idx*4, X=画面x, Y=アイテムY
	lda <ITEM_IDX
	asl a
	asl a
	clc
	adc #22
	sta <T6
	ldy <ITEM_IDX
	lda ITEM_Y,y
	tay
	ldx <T5
	lda <T6
	jsr SetSprite16
	jmp .next
.hide
	lda <ITEM_IDX
	asl a
	asl a
	clc
	adc #22
	jsr HideSprite16
.next
	inc <ITEM_IDX
	lda <ITEM_IDX
	cmp #2
	beq .done
	jmp .item
.done
	rts

;------------------------------------------------------------------------------
; 土管との当たり判定 + 通過スコア
;   f = (scroll + BIRD_X+12 - slotX) & 511
;   f<=40:横重なり → ゲート内かチェック / 41<=f<=100:通過済みチェック
;------------------------------------------------------------------------------
CollisionCheck:
	; W = scroll + (BIRD_X+12)
	lda <SCROLL_L
	clc
	adc #BIRD_X+12
	sta <T2			; WL
	lda <SCROLL_H
	adc #0
	sta <T3			; WH
	ldx #0
.slot
	lda PIPE_ACT,x
	bne .chk
	jmp .next
.chk
	lda <T2
	sec
	sbc SlotXLo,x
	sta <T0			; f_lo
	lda <T3
	sbc SlotXHi,x
	and #$01
	beq .inrange
	jmp .next		; f >= 256
.inrange
	lda <T0
	cmp #41
	bcs .passchk
	; ---- 横重なり: ゲート内チェック ----
	lda <STAR_TIMER
	beq .mortal
	jmp .next		; スター無敵
.mortal
	lda PIPE_GAP,x
	asl a
	asl a
	asl a
	sta <T1			; gap*8
	lda <BIRD_Y
	clc
	adc #5
	cmp <T1			; birdY+5 < gap*8 → 上の土管にヒット
	bcc .die
	lda PIPE_GAPSZ,x
	asl a
	asl a
	asl a
	clc
	adc <T1
	sta <T1			; ゲート下端 = (gap+幅)*8
	lda <BIRD_Y
	clc
	adc #12
	cmp <T1
	bcs .die		; birdY+12 >= 下端 → 下の土管にヒット
	jmp .next
.die
	jmp BirdDie
.passchk
	; ---- 通過スコア ----
	lda <T0
	cmp #101
	bcs .next
	lda PIPE_PASS,x
	bne .next
	lda #1
	sta PIPE_PASS,x
	lda PIPE_BOSS,x
	bne .bosspass
	txa
	pha
	lda #SE_POINT
	jsr sfx_play
	lda #1
	ldx #0
	jsr ScoreAdd
	pla
	tax
	jmp .passdone
.bosspass
	txa
	pha
	lda #SE_FANFARE
	jsr sfx_play
	lda #3
	ldx #0
	jsr ScoreAdd
	lda #%10000000		; 実績: BOSS BREAKER
	jsr AchSet
	pla
	tax
.passdone
.next
	inx
	cpx #4
	beq .done
	jmp .slot
.done
	rts

;==============================================================================
; シーン: ゲームオーバー
;==============================================================================
SceneOver:
	lda <INITED
	beq .init
	jmp OverUpdate
.init
	; ---- 初期化 (描画はONのまま, オーバーレイ表示) ----
	; ハイスコア更新
	ldx #5
.hicmp
	lda <SCORE,x
	cmp <HISCORE,x
	bcc .nohigh
	bne .newhigh
	dex
	bpl .hicmp
	jmp .nohigh
.newhigh
	ldx #5
.hicopy
	lda <SCORE,x
	sta <HISCORE,x
	sta ACH_HISCORE,x
	dex
	bpl .hicopy
	lda #1
	sta <NEWREC
.nohigh
	; GAMEOVERロゴをオーバーレイ (タイル$44, 9x3, 画面中央)
	; スクロール列 = scrollX>>3
	lda <SCROLL_L
	lsr a
	lsr a
	lsr a
	sta <T5
	lda <SCROLL_H
	and #$01
	beq .nthi
	lda <T5
	ora #$20
	sta <T5
.nthi
	lda #0
	sta <T6			; k
.ovcol
	; 列 = (scrollcol + 11 + k) & 63
	lda <T5
	clc
	adc #11
	clc
	adc <T6
	and #$3F
	sta <T7
	; バッファに縦3タイルのエントリを追加
	ldx <BUF_LEN
	lda #3
	sta VBUF,x
	inx
	; addrH = $80 | $20 | NT | 1 (行11 → 11>>3=1)
	lda <T7
	and #$20
	lsr a
	lsr a
	lsr a
	ora #$A1		; $80|$20|1
	sta VBUF,x
	inx
	; addrL = (11&7)<<5 | col = $60 | col
	lda <T7
	and #$1F
	ora #$60
	sta VBUF,x
	inx
	; タイル3枚
	lda #$44
	clc
	adc <T6
	sta VBUF,x
	inx
	clc
	adc #$10
	sta VBUF,x
	inx
	clc
	adc #$10
	sta VBUF,x
	inx
	lda #0
	sta VBUF,x
	stx <BUF_LEN
	inc <T6
	lda <T6
	cmp #9
	bne .ovcol
	lda #1
	sta <BUF_READY

	; ジングル
	lda #MUS_OVER
	jsr music_play

	lda #240
	sta <SCR_TIMER
	lda #1
	sta <INITED
	rts

OverUpdate:
	; タイマー236でメダル, 230でNEW RECORD を順次表示 (VBlank負荷分散)
	lda <SCR_TIMER
	cmp #236
	bne .nmedal
	jsr DrawMedal
.nmedal
	lda <SCR_TIMER
	cmp #230
	bne .nrec
	lda <NEWREC
	beq .nrec
	jsr DrawNewRec
	lda #SE_STAR
	jsr sfx_play
.nrec
	; START/Aでタイトル, または時間切れ
	lda <PAD_TRG
	and #PAD_ST|PAD_A
	bne .totitle
	dec <SCR_TIMER
	bne .stay
.totitle
	lda #SC_TITLE
	jmp ChangeScene
.stay
	rts

;------------------------------------------------------------------------------
; 星パーティクル: 発生
;  IN T0:x  T1:y  A:個数
;------------------------------------------------------------------------------
PartSpawn:
	sta <T2			; 残り個数
	ldx #4
.find
	lda PART_LIFE,x
	bne .next
	; 空きスロットに生成
	lda <T0
	sta PART_X,x
	lda <T1
	sta PART_Y,x
	; 速度: (RNG+FRAME+slot)&7 でテーブル引き
	stx <T3
	lda <RNG
	clc
	adc <FRAME_CNT
	clc
	adc <T3
	and #$07
	tay
	lda PartVelX,y
	sta PART_DX,x
	lda PartVelY,y
	sta PART_DY,x
	lda #14
	sta PART_LIFE,x
	jsr RngStep
	dec <T2
	beq .done
.next
	dex
	bpl .find
.done
	rts

;------------------------------------------------------------------------------
; 星パーティクル: 更新+描画 (スプライト30-34)
;------------------------------------------------------------------------------
PartUpdate:
	ldx #4
.loop
	lda PART_LIFE,x
	beq .hide
	dec PART_LIFE,x
	; 移動
	lda PART_X,x
	clc
	adc PART_DX,x
	sta PART_X,x
	lda PART_Y,x
	clc
	adc PART_DY,x
	sta PART_Y,x
	; OAM書き込み
	txa
	clc
	adc #30
	asl a
	asl a
	tay
	lda PART_Y,x
	sta OAM_BUF,y
	lda PART_LIFE,x
	cmp #7
	bcs .big
	lda #$EF		; 消えかけは小さい星
	jmp .tset
.big
	lda #$EE
.tset
	sta OAM_BUF+1,y
	lda #%00000011		; パレット3(金)
	sta OAM_BUF+2,y
	lda PART_X,x
	sta OAM_BUF+3,y
	jmp .pnext
.hide
	txa
	clc
	adc #30
	asl a
	asl a
	tay
	lda #$FF
	sta OAM_BUF,y
.pnext
	dex
	bpl .loop
	rts

PartVelX:	.db $FE,$FF,$FD,$01,$FF,$02,$00,$FD
PartVelY:	.db $FF,$FE,$01,$FE,$02,$FF,$FD,$00

;------------------------------------------------------------------------------
; 得点ポップ発生 IN T0:x T1:y A:十の位(0=なし) X:一の位
;------------------------------------------------------------------------------
PopSpawn:
	cmp #0
	bne .tens
	lda #$FF
	jmp .set
.tens
	; 値そのままが小数字タイル番号
.set
	sta POP_D1
	stx POP_D2
	lda <T0
	sta POP_X
	lda <T1
	sec
	sbc #6
	sta POP_Y
	lda #36
	sta POP_T
	rts

;------------------------------------------------------------------------------
; 得点ポップ更新 (スプライト47,48) ふわっと上昇して消える
;------------------------------------------------------------------------------
PopUpdate:
	lda POP_T
	bne .live
	; 非表示
	lda #$FF
	sta OAM_BUF+188		; 47*4
	sta OAM_BUF+192		; 48*4
	rts
.live
	dec POP_T
	; 2フレームに1px上昇
	lda <FRAME_CNT
	and #$01
	bne .draw
	dec POP_Y
.draw
	; 十の位 (スプライト47)
	lda POP_D1
	cmp #$FF
	beq .noten
	lda POP_Y
	sta OAM_BUF+188
	lda POP_D1
	sta OAM_BUF+189
	lda #%00000010
	sta OAM_BUF+190
	lda POP_X
	sta OAM_BUF+191
	jmp .ones
.noten
	lda #$FF
	sta OAM_BUF+188
.ones
	; 一の位 (スプライト48)
	lda POP_Y
	sta OAM_BUF+192
	lda POP_D2
	sta OAM_BUF+193
	lda #%00000010
	sta OAM_BUF+194
	lda POP_X
	clc
	adc #7
	sta OAM_BUF+195
	rts

;------------------------------------------------------------------------------
; 風の状態更新 + 風パーティクル (葉っぱ/風の粒, スプライト41-46)
;------------------------------------------------------------------------------
WindUpdate:
	; タイマー (4フレームに1回減算)
	lda <FRAME_CNT
	and #$03
	bne .particles
	dec <WIND_TMR
	bne .particles
	; 状態遷移
	lda <WIND_DIR
	beq .roll
	; 風→無風
	lda #0
	sta <WIND_DIR
	lda #100
	sta <WIND_TMR
	jmp .particles
.roll
	; 無風→抽選 (0:上昇 1:下降 2,3:無風続行)
	jsr RngStep
	lda <RNG
	and #$03
	beq .windup
	cmp #1
	beq .winddn
	lda #70
	sta <WIND_TMR
	jmp .particles
.windup
	lda #1
	jmp .windset
.winddn
	lda #$FF
.windset
	sta <WIND_DIR
	lda #45			; 約3秒
	sta <WIND_TMR
	jsr WindScatter
	lda #SE_WIND
	jsr sfx_play
.particles
	; ---- パーティクル更新 ----
	ldx #5
.wp
	lda <WIND_DIR
	beq .wphide
	; X -= 2 (背景より速く流れる = 風感)
	lda WP_X,x
	sec
	sbc #2
	sta WP_X,x
	cmp #4
	bcs .wpy
	; 左端: 右へ再出現
	jsr RngStep
	lda <RNG
	sta WP_Y,x
	and #$3F
	clc
	adc #180
	sta WP_X,x
	lda WP_Y,x
	and #$7F
	clc
	adc #40
	sta WP_Y,x
.wpy
	; Y: 風向き + ゆらぎ
	lda <WIND_DIR
	bmi .wpdn
	dec WP_Y,x
	jmp .wpwob
.wpdn
	inc WP_Y,x
.wpwob
	lda <FRAME_CNT
	lsr a
	lsr a
	lsr a
	stx <T0
	clc
	adc <T0
	and #$03
	tay
	lda WobTbl,y
	clc
	adc WP_Y,x
	sta WP_Y,x
	; OAM (スプライト41+x)
	txa
	clc
	adc #41
	asl a
	asl a
	tay
	lda WP_Y,x
	sta OAM_BUF,y
	txa
	and #$01
	bne .wleaf
	lda #$0D		; 風の粒(白)
	sta OAM_BUF+1,y
	lda #%00000010
	sta OAM_BUF+2,y
	jmp .wx
.wleaf
	lda #$0C		; 葉っぱ(緑)
	sta OAM_BUF+1,y
	lda #%00000011
	sta OAM_BUF+2,y
.wx
	lda WP_X,x
	sta OAM_BUF+3,y
	jmp .wpnext
.wphide
	txa
	clc
	adc #41
	asl a
	asl a
	tay
	lda #$FF
	sta OAM_BUF,y
.wpnext
	dex
	bmi .wpdone
	jmp .wp
.wpdone
	rts

; 風開始時にパーティクルをばらまく
WindScatter:
	ldx #5
.sc
	jsr RngStep
	lda <RNG
	sta WP_X,x
	jsr RngStep
	lda <RNG
	and #$7F
	clc
	adc #40
	sta WP_Y,x
	dex
	bpl .sc
	rts

WobTbl:	.db 0,1,0,$FF

;------------------------------------------------------------------------------
; スクロール加速 (スコア30で1.25px/f, 70で1.5px/f)
;------------------------------------------------------------------------------
SpeedUpdate:
	lda <SCORE+2
	ora <SCORE+3
	ora <SCORE+4
	ora <SCORE+5
	bne .fast2
	lda <SCORE+1
	cmp #7
	bcs .fast2
	cmp #3
	bcs .fast1
	lda #0
	sta <SPEED_ADD
	rts
.fast1
	lda #$40
	sta <SPEED_ADD
	rts
.fast2
	lda #$80
	sta <SPEED_ADD
	rts

;------------------------------------------------------------------------------
; パレット位相 (10点ごとに 昼→夕焼け→夜→昼...)
;------------------------------------------------------------------------------
PalPhaseUpdate:
	ldx <SCORE+1		; 十の位
	lda Mod3Tbl,x
	cmp <PALPHASE
	beq .done
	sta <PALPHASE
	asl a
	asl a
	asl a
	asl a			; x16
	tax
	ldy #0
.copy
	lda PalPhases,x
	sta PAL_BUF,y
	inx
	iny
	cpy #16
	bne .copy
	; $3F10ミラー対策: スプライト側先頭も空色に
	lda PAL_BUF
	sta PAL_BUF+16
	lda #1
	sta <PAL_DIRTY
	; 節目ファンファーレ
	lda #SE_FANFARE
	jsr sfx_play
.done
	rts

;------------------------------------------------------------------------------
; ゲームオーバーのメダル表示
;------------------------------------------------------------------------------
DrawMedal:
	; スコア判定: >=50 金 / >=20 銀 / >=5 銅
	lda <SCORE+2
	ora <SCORE+3
	ora <SCORE+4
	ora <SCORE+5
	bne .gold
	lda <SCORE+1
	cmp #5
	bcs .gold
	cmp #2
	bcs .silver
	cmp #1
	bcs .bronze		; 10-19点
	lda <SCORE
	cmp #5
	bcs .bronze		; 5-9点
	rts			; メダルなし
.gold
	lda #low(StrGold)
	sta <PTR_L
	lda #high(StrGold)
	sta <PTR_H
	lda #11
	jmp .draw
.silver
	lda #low(StrSilver)
	sta <PTR_L
	lda #high(StrSilver)
	sta <PTR_H
	lda #10
	jmp .draw
.bronze
	lda #low(StrBronze)
	sta <PTR_L
	lda #high(StrBronze)
	sta <PTR_H
	lda #10
.draw
	sta <T4			; 画面列
	lda #16			; 行
	sta <T5
	jmp OverText

DrawNewRec:
	lda #low(StrNewRec)
	sta <PTR_L
	lda #high(StrNewRec)
	sta <PTR_H
	lda #11
	sta <T4
	lda #18
	sta <T5
	jmp OverText

;------------------------------------------------------------------------------
; スクロール補正つきテキストオーバーレイ (ゲームオーバー画面用)
;  IN PTR_L/H:文字列(';'終端)  T4:画面列  T5:行
;------------------------------------------------------------------------------
OverText:
	; スクロール列
	lda <SCROLL_L
	lsr a
	lsr a
	lsr a
	sta <T6
	lda <SCROLL_H
	and #$01
	beq .nt0
	lda <T6
	ora #$20
	sta <T6
.nt0
	ldy #0
.ch
	lda [PTR_L],y
	cmp #';'
	beq .done
	cmp #' '
	beq .skip
	pha
	; 列 = (scrollcol + T4 + y) & 63
	sty <T7
	lda <T6
	clc
	adc <T4
	clc
	adc <T7
	and #$3F
	sta <T7
	ldx <BUF_LEN
	lda #1
	sta VBUF,x
	inx
	; addrH = $20 | NT | (行>>3)
	lda <T7
	and #$20
	lsr a
	lsr a
	lsr a
	sta <T2
	lda <T5
	lsr a
	lsr a
	lsr a
	clc
	adc <T2
	clc
	adc #$20
	sta VBUF,x
	inx
	; addrL = (行&7)<<5 | 列&31
	lda <T5
	and #$07
	asl a
	asl a
	asl a
	asl a
	asl a
	sta <T2
	lda <T7
	and #$1F
	ora <T2
	sta VBUF,x
	inx
	pla
	clc
	adc #STR2CHR
	sta VBUF,x
	inx
	lda #0
	sta VBUF,x
	stx <BUF_LEN
.skip
	iny
	bne .ch
.done
	lda #1
	sta <BUF_READY
	rts

;==============================================================================
; シーン: スタッフロール
;==============================================================================
SceneStaff:
	lda <INITED
	beq .init
	jmp StaffUpdate
.init
	lda #0
	sta <PPU_ON
	sta PPUMASK
	sta <SCROLL_L
	sta <SCROLL_H
	sta <SCROLL_Y
	jsr SpriteInit
	lda #%10001000
	sta PPUCTRL
	bit PPUSTAT
	; NT0を空タイルで埋める
	lda #$20
	sta PPUADDR
	lda #$00
	sta PPUADDR
	lda #TILE_SKY
	ldx #$C0
	ldy #3
.fill1
	sta PPUDATA
	dex
	bne .fill1
.fill2
	sta PPUDATA
	dex
	bne .fill2
	dey
	bne .fill2
	; 属性: 全部パレット1
	lda #%01010101
	ldx #64
.attr
	sta PPUDATA
	dex
	bne .attr
	; テキスト配置
	jsr StaffPrintAll
	; パレット
	lda #low(tilepal_logo)
	sta <PTR_L
	lda #high(tilepal_logo)
	sta <PTR_H
	jsr PalLoad
	; 背景色は黒に明示
	lda #$0F
	sta PAL_BUF
	sta PAL_BUF+16
	; BGM
	lda #MUS_STAFF
	jsr music_play
	lda #1
	sta <INITED
	lda #2
	sta <PPU_ON
	rts

StaffUpdate:
	lda <PAD_TRG
	and #PAD_A|PAD_ST
	beq .stay
	lda #SE_SELECT
	jsr sfx_play
	lda #SC_TITLE
	jmp ChangeScene
.stay
	rts

; スタッフロールの全行を描く
StaffPrintAll:
	lda #low(StrStaff1)
	sta <PTR_L
	lda #high(StrStaff1)
	sta <PTR_H
	lda #3
	sta <T4
	lda #5
	sta <T5
	jsr TextPrint
	lda #low(StrStaff2)
	sta <PTR_L
	lda #high(StrStaff2)
	sta <PTR_H
	lda #5
	sta <T4
	lda #7
	sta <T5
	jsr TextPrint
	lda #low(StrStaff3)
	sta <PTR_L
	lda #high(StrStaff3)
	sta <PTR_H
	lda #3
	sta <T4
	lda #11
	sta <T5
	jsr TextPrint
	lda #low(StrStaff4)
	sta <PTR_L
	lda #high(StrStaff4)
	sta <PTR_H
	lda #5
	sta <T4
	lda #13
	sta <T5
	jsr TextPrint
	lda #low(StrStaff5)
	sta <PTR_L
	lda #high(StrStaff5)
	sta <PTR_H
	lda #3
	sta <T4
	lda #17
	sta <T5
	jsr TextPrint
	lda #low(StrStaff6)
	sta <PTR_L
	lda #high(StrStaff6)
	sta <PTR_H
	lda #5
	sta <T4
	lda #19
	sta <T5
	jsr TextPrint
	lda #low(StrStaff7)
	sta <PTR_L
	lda #high(StrStaff7)
	sta <PTR_H
	lda #6
	sta <T4
	lda #25
	sta <T5
	jsr TextPrint
	rts

;==============================================================================
; シーン: 実績 (AWARDS)
;==============================================================================
SceneAwards:
	lda <INITED
	beq .init
	jmp AwardsUpdate
.init
	lda #0
	sta <PPU_ON
	sta PPUMASK
	sta <SCROLL_L
	sta <SCROLL_H
	sta <SCROLL_Y
	jsr SpriteInit
	lda #%10001000
	sta PPUCTRL
	bit PPUSTAT
	; NT0を空タイルで埋める
	lda #$20
	sta PPUADDR
	lda #$00
	sta PPUADDR
	lda #TILE_SKY
	ldx #$C0
	ldy #3
.fill1
	sta PPUDATA
	dex
	bne .fill1
.fill2
	sta PPUDATA
	dex
	bne .fill2
	dey
	bne .fill2
	lda #%01010101
	ldx #64
.attr
	sta PPUDATA
	dex
	bne .attr
	; ヘッダ
	lda #low(StrAwHead)
	sta <PTR_L
	lda #high(StrAwHead)
	sta <PTR_H
	lda #12
	sta <T4
	lda #3
	sta <T5
	jsr TextPrint
	; 実績リスト 8行 (行8,10,...,22)
	lda #0
	sta <T3			; 実績番号
.list
	; 名前
	lda <T3
	asl a
	tay
	lda AchNameTbl,y
	sta <PTR_L
	lda AchNameTbl+1,y
	sta <PTR_H
	lda #10
	sta <T4
	lda <T3
	asl a
	clc
	adc #8
	sta <T5
	jsr TextPrint
	; 解除済みならハートを列8に
	ldx <T3
	lda AchBitTbl,x
	and ACH_FLAGS
	beq .locked
	; アドレス = $2000 + 行*32 + 8
	lda <T3
	asl a
	clc
	adc #8
	sta <T5
	lsr a
	lsr a
	lsr a
	clc
	adc #$20
	sta PPUADDR
	lda <T5
	and #$07
	asl a
	asl a
	asl a
	asl a
	asl a
	clc
	adc #8
	sta PPUADDR
	lda #$CF		; ハート
	sta PPUDATA
.locked
	inc <T3
	lda <T3
	cmp #8
	bne .list
	; 解除数 "N OF 8" (行25)
	lda ACH_FLAGS
	ldx #0
.cnt
	lsr a
	bcc .cnt2
	inx
.cnt2
	bne .cnt
	txa
	pha
	lda #low(StrAwCnt)
	sta <PTR_L
	lda #high(StrAwCnt)
	sta <PTR_H
	lda #13
	sta <T4
	lda #25
	sta <T5
	jsr TextPrint
	; 数字を直接 (行25 列11)
	lda #$23
	sta PPUADDR
	lda #$2B		; 行25(=$2320)+11
	sta PPUADDR
	pla
	clc
	adc #$C0
	sta PPUDATA
	; パレット
	lda #low(tilepal_logo)
	sta <PTR_L
	lda #high(tilepal_logo)
	sta <PTR_H
	jsr PalLoad
	lda #$0F
	sta PAL_BUF
	sta PAL_BUF+16
	lda #1
	sta <INITED
	lda #2
	sta <PPU_ON
	rts

AwardsUpdate:
	lda <PAD_TRG
	and #PAD_A|PAD_B|PAD_ST
	beq .stay
	lda #SE_SELECT
	jsr sfx_play
	lda #SC_TITLE
	jmp ChangeScene
.stay
	rts

;==============================================================================
; データ (バンク1)
;==============================================================================
	.bank 1
	.org $A000

; --- サウンドドライバ ---
	.include "src/sound.asm"

; --- 土管スロットのX座標 (NT空間, 128px間隔) ---
SlotXLo:	.db $00,$80,$00,$80
SlotXHi:	.db $00,$00,$01,$01
; 土管スロットの属性バイトアドレス (行20-23のセル)
PipeAttrHi:	.db $23,$23,$27,$27
PipeAttrLo:	.db $E8,$EC,$E8,$EC
PipeAttrCell:	.db $00,$04,$00,$04

; --- ステージBGM候補 (16エントリ, rng&15で引く) ---
StageBgmTbl:	.db MUS_STAGE, MUS_IDOL, MUS_CUTE, MUS_HERO, MUS_SWING
		.db MUS_TURK, MUS_ENT, MUS_CANCAN, MUS_KOROB, MUS_TECH
		.db MUS_STAGE, MUS_TURK, MUS_CANCAN, MUS_KOROB, MUS_IDOL, MUS_TECH

; --- キャラ別性能 (翔子/マミタス/クリオネコ/女のコ/翔子まりお) ---
CharGravity:	.db $30,$22,$3E,$2C,$36
CharFlapLo:	.db $40,$A0,$00,$60,$E0
CharFlapHi:	.db $FD,$FD,$FD,$FD,$FC

; --- コンボボーナス (一の位, 十の位) index=コンボ数0-4 ---
ComboOnes:	.db 0,5,0,5,0
ComboTens:	.db 0,0,1,1,2

; --- ランクゲージ: 各ランク5セルのしきい値 (十の位,一の位) ---
RankCellTbl:	.db 0,1, 0,2, 0,3, 0,4, 0,5	; ランク1 (0-4点)
		.db 0,8, 1,1, 1,4, 1,7, 2,0	; ランク2 (5-19点)
		.db 2,6, 3,2, 3,8, 4,4, 5,0	; ランク3 (20-49点)
		.db 6,0, 7,0, 8,0, 9,0, 9,9	; ランク4 (50-99点)

; --- 十の位 -> パレット位相 ---
Mod3Tbl:	.db 0,1,2,0,1,2,0,1,2,0

; --- パレット位相 (昼/夕焼け/夜) 各16byte ---
PalPhases:	.db $21,$0F,$09,$2A, $21,$23,$27,$15, $21,$3A,$30,$27, $21,$07,$17,$26
		.db $36,$0F,$09,$2A, $36,$23,$27,$15, $36,$26,$30,$16, $36,$07,$17,$26
		.db $02,$0F,$09,$2A, $02,$23,$27,$15, $02,$00,$10,$26, $02,$07,$17,$26

; --- 待機中のふわふわテーブル ---
BobTbl:		.db 0,1,2,3,4,3,2,1

; --- ステージBGパレット (空を水色に) ---
PalStageBG:	.db $21,$0F,$09,$2A	; 空/土管/草
		.db $21,$23,$27,$15	; 地面
		.db $21,$3A,$30,$27	; 雲/ビル
		.db $21,$07,$17,$26	; 地下

; --- キャラクタパレット (原作より: 4行/キャラ, 行0=上段 行2=下段に使用) ---
CharaPalTbl:	.db $21,$20,$3F,$17	; 翔子
		.db $21,$20,$3F,$17
		.db $21,$20,$3F,$17
		.db $21,$20,$3F,$17
		.db $21,$30,$07,$37	; マミタス
		.db $21,$30,$07,$37
		.db $21,$30,$07,$37
		.db $21,$30,$07,$37
		.db $21,$30,$3F,$24	; クリオネコ
		.db $21,$30,$3F,$24
		.db $21,$30,$3F,$24
		.db $21,$30,$3F,$24
		.db $21,$25,$27,$11	; 女のコ
		.db $21,$36,$27,$15
		.db $21,$36,$3F,$15
		.db $21,$36,$19,$15
		.db $3F,$36,$24,$06	; 翔子まりお
		.db $3F,$36,$24,$06
		.db $3F,$36,$24,$2C
		.db $3F,$36,$24,$2C

; --- 文字列 (';'終端) ---
StrGameStart:	.db "GAME START;"
StrStaffRoll:	.db "STAFF ROLL;"
StrAwards:	.db "AWARDS;"
StrCharaHint:	.db "PUSH <B> CHANGE BIRD;"
StrCopyright:	.db "2014 2026 SAYONARI;"
StrHi:		.db "HI;"
StrStaff1:	.db "DEVELOPED BY:;"
StrStaff2:	.db "RYOTA NISHIMURA <SAYONARI>;"
StrStaff3:	.db "REIMPLEMENTED 2026 BY:;"
StrStaff4:	.db "SAYONARI AND CLAUDE;"
StrStaff5:	.db "SPECIAL THANKS:;"
StrStaff6:	.db "SHOKO NAKAGAWA;"
StrStaff7:	.db "PUSH <A> TO TITLE;"
StrGold:	.db "GOLD MEDAL;"
StrSilver:	.db "SILVER MEDAL;"
StrBronze:	.db "BRONZE MEDAL;"
StrNewRec:	.db "NEW RECORD;"
StrAwHead:	.db "AWARDS;"
StrAwCnt:	.db "OF 8;"
AchBitTbl:	.db $01,$02,$04,$08,$10,$20,$40,$80
AchNameTbl:	.dw StrAch0
	.dw StrAch1
	.dw StrAch2
	.dw StrAch3
	.dw StrAch4
	.dw StrAch5
	.dw StrAch6
	.dw StrAch7
StrAch0:	.db "FIRST FLIGHT;"
StrAch1:	.db "SCORE 5;"
StrAch2:	.db "SCORE 50;"
StrAch3:	.db "SCORE 100;"
StrAch4:	.db "COMBO MASTER;"
StrAch5:	.db "STAR RIDER;"
StrAch6:	.db "SECRET PAGE;"
StrAch7:	.db "BOSS BREAKER;"

; --- 隠しページ: 行ごとの文字列と開始列 (30行 x 3byte) ---
SecretRowTbl:
	.dw $0000
	.db 0			; 行0
	.dw $0000
	.db 0			; 行1
	.dw $0000
	.db 0			; 行2
	.dw $0000
	.db 0			; 行3
	.dw StrSec1
	.db 8			; 行4
	.dw $0000
	.db 0			; 行5
	.dw $0000
	.db 0			; 行6
	.dw $0000
	.db 0			; 行7
	.dw StrSec2
	.db 8			; 行8
	.dw $0000
	.db 0			; 行9
	.dw $0000
	.db 0			; 行10
	.dw StrSec3
	.db 3			; 行11
	.dw $0000
	.db 0			; 行12
	.dw $0000
	.db 0			; 行13
	.dw $0000
	.db 0			; 行14
	.dw StrSec4
	.db 4			; 行15
	.dw $0000
	.db 0			; 行16
	.dw StrSec5
	.db 7			; 行17
	.dw $0000
	.db 0			; 行18
	.dw $0000
	.db 0			; 行19
	.dw $0000
	.db 0			; 行20
	.dw StrSec6
	.db 6			; 行21
	.dw $0000
	.db 0			; 行22
	.dw StrSec7
	.db 3			; 行23
	.dw $0000
	.db 0			; 行24
	.dw $0000
	.db 0			; 行25
	.dw $0000
	.db 0			; 行26
	.dw StrSec8
	.db 11			; 行27
	.dw $0000
	.db 0			; 行28
	.dw $0000
	.db 0			; 行29

StrSec1:	.db "? SECRET PAGE ?;"
StrSec2:	.db "CONGRATULATIONS;"
StrSec3:	.db "YOU FOUND THE HIDDEN ROOM;"
StrSec4:	.db "FAMILYBIRD 2014 TO 2026;"
StrSec5:	.db "THANKS FOR PLAYING;"
StrSec6:	.db "GIFT: RAINBOW START;"
StrSec7:	.db "PUSH START: FLY WITH A STAR;"
StrSec8:	.db "? ? ? ? ?;"

; --- ロゴ画面パレット/ネームテーブル ---
tilepal_logo:	.incbin "assets/FamiBird_logo.dat"
bglogo:		.incbin "assets/logo.nam"

; --- バンク2/3に入りきらない楽曲ストリーム ---
	.include "build/songs3.asm"

;==============================================================================
; バンク2 ($C000-) 音楽データ
;==============================================================================
	.bank 2
	.org $C000
	.include "build/songs.asm"
	.include "build/dpcm_tables.asm"

;==============================================================================
; バンク3 ($E000-) DPCMサンプル + 割り込みベクタ
;==============================================================================
	.bank 3
	.org $E000
dpcm_start:
	.incbin "build/dpcm.bin"

	; バンク2に入りきらない楽曲ストリーム
	.include "build/songs2.asm"

	.org $FFFA
	.dw NMI
	.dw Reset
	.dw IRQ

;==============================================================================
; バンク4 CHR-ROM
;==============================================================================
	.bank 4
	.org $0000
	.incbin "build/FamiBird2.chr"
