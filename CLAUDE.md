# FamilyBird2 プロジェクト

原作 `../FamilyBird/`（2014, nesasm製ファミコンゲーム）のクリーン再実装．詳細は README.md 参照．

## ルール
- ビルドは必ず `./build.sh`（CHRパッチ→DPCM生成→楽曲コンパイル→nesasm の順序依存があるため）
- 検証は `python3 test/scenario.py` と `python3 test/autopilot.py`（ヘッドレスエミュレータ）
- 実機確認は Mesen.app で `build/FamilyBird2.nes` を開く
- このプロジェクトは private_work 配下（ROM等を含む私的領域）のため Google Drive へは同期しない
- 楽曲をいじるときは songs/*.mml を編集（tools/songc.py の記法コメント参照）

## 設計メモ
- NMIは OAM DMA / VRAMバッファ($0300)転送 / パレット転送 / スクロール / サウンド のみ．ロジックはメインループ
- 土管は4スロット×128px間隔の循環方式．画面外左でゲート再抽選し2フレームに分けて再描画
- 土管はNT属性セル(4列)に整列しており，背景帯との色衝突は属性1バイトの書き換えで解決
- VBlank予算: バッファ最大約60〜80バイト/フレームに抑制（リサイクル2分割・移動延期ロジック）
- ゼロページ配置は src/main.asm 冒頭と src/sound.asm 冒頭（$50-$5F, $4D はサウンド用）
