#!/bin/bash
# FamilyBird2 ビルドスクリプト
set -e
cd "$(dirname "$0")"
mkdir -p build

echo "=== CHRパッチ (アイテムタイル追加) ==="
python3 tools/chr_patch.py

echo "=== DPCM打楽器生成 ==="
python3 tools/dpcm_gen.py

echo "=== 楽曲コンパイル ==="
python3 tools/songc.py

echo "=== DPCMテーブル生成 ==="
python3 - <<'PY'
import sys
sys.path.insert(0, 'build')
from dpcm_meta import DPCM_META, DPCM_TOTAL
order = ['kick','tom_hi','tom_lo','snare']
rates = {'kick':0x0F,'tom_hi':0x0F,'tom_lo':0x0F,'snare':0x0F}
lines = ['; 自動生成: DPCMサンプルテーブル (dpcm_start=$E000)']
lines.append('dpcm_rate_table:\t.db ' + ','.join('$%02X'%rates[n] for n in order))
lines.append('dpcm_addr_table:\t.db ' + ','.join('$%02X'%((0xE000+DPCM_META[n][0]-0xC000)//64) for n in order))
lines.append('dpcm_len_table:\t.db ' + ','.join('$%02X'%((DPCM_META[n][1]-1)//16+0 if False else (DPCM_META[n][1]>>4)) for n in order))
open('build/dpcm_tables.asm','w').write('\n'.join(lines)+'\n')
print('dpcm_tables.asm generated, total %d bytes' % DPCM_TOTAL)
PY

echo "=== アセンブル ==="
~/bin/nesasm -s src/main.asm -o build/FamilyBird2.nes > build/asm.log 2>&1 || { cat build/asm.log; exit 1; }
tail -20 build/asm.log
ls -la build/FamilyBird2.nes
echo "=== ビルド完了 ==="
