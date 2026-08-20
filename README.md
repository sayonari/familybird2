# FamilyBird 2

**▶ ブラウザで遊ぶ: https://sayonari.github.io/familybird2/**

原作 **FamilyBird**（2014, Ryota NISHIMURA）のクリーン再実装版．
フラッピーバード型ゲーム．鳥（翔子・マミタス・クリオネコ・女のコ・翔子まりお）を操作して
マリオ風の土管を避けて進む．

## 原作からの改善点

| 項目 | 原作 (2014) | 本作 (2026) |
|---|---|---|
| プログラム構造 | 全ロジックがNMIハンドラ内 | メインループ + NMI(DMA/転送/音のみ) の分離 |
| VRAM書き込み | 描画中に直接書き込み(画面化け) | VBlank内バッファ転送方式 |
| 当たり判定 | 描画中のVRAMを$2007で読む | 数学的判定(座標計算) |
| ミラーリング | 水平(横スクロール不適) | 垂直 + 2画面無限スクロール |
| 土管 | 固定2本・1画面ループ | 4スロット循環・無限生成・乱数ゲート |
| 土管の動き | なし | スコア10以降，上下移動する土管が出現 |
| スコア | 経過秒数 | 土管通過 +1 / アイテムボーナス |
| アイテム | なし | コイン(+5) チェリー(+20) スター(無敵) |
| 音楽 | NSD.Lib (2曲+SE) | 自作5chドライバ「SAYODRV」+ DPCM打楽器 |
| ハイスコア | なし | タイトル画面に表示(電源断まで保持) |

## 操作

- **A**: 羽ばたき / 決定
- **B**: キャラクター変更（タイトル・ゲーム中いつでも）
- **SELECT / 上下**: タイトルメニュー選択
- **START**: 決定

## ビルド

```sh
./build.sh          # build/FamilyBird2.nes が生成される
```

必要環境: nesasm 3.6 (ClusterM版, ~/bin/nesasm), Python 3

## 構成

```
src/main.asm      メインプログラム (シーン/物理/土管/アイテム/描画)
src/sound.asm     サウンドドライバ SAYODRV (5ch + SFX 2系統)
songs/*.mml       楽曲データ (MML風テキスト, 4曲)
tools/songc.py    楽曲コンパイラ (MML -> ドライバ用データ)
tools/dpcm_gen.py DPCM打楽器合成 (キック/タム高低/スネア, SMB3風)
tools/chr_patch.py 原作CHRにアイテム絵(コイン/スター/チェリー)を追加
assets/           原作から流用のCHR/パレット/ロゴ
test/emu.py       検証用ヘッドレスNESエミュレータ (6502+最小PPU/APU)
test/scenario.py  通しテスト / test/autopilot.py 自動プレイテスト
test/apu_render.py APUログ -> WAV (BGM試聴用)
```

## 音楽

- タイトル: あたたかい8小節ループ
- ステージ: アップテンポ16小節 (DPCMキック/タム = マリオ3風打楽器)
- ゲームオーバー: 下降ジングル
- スタッフロール: ワルツ

`build/bgm_*.wav` で試聴可能（テストレンダラ出力）．

## ブラウザ版 (docs/)

GitHub Pages で公開しているブラウザ版は [jsnes](https://github.com/bfirsh/jsnes)（MITライセンス）で
`FamilyBird2.nes` をそのまま実行しています．タッチ操作・ゲームパッド対応．

## 権利

個人の技術確認用．ゲーム原案 FlappyBird: Dong Nguyen．
キャラクタ・グラフィックは2014年の原作アセットを使用．外部配布はしない．
