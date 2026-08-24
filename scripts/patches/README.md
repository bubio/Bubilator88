# 参照エミュレータ用ローカルパッチ

このリポジトリのコードではなく、**比較対象のエミュレータに当てるパッチ**を
置く場所。上流に投げる予定はなく、向こうの clone では未コミットの作業ツリー
状態で存在するため、`git checkout` 一発や再 clone で消える。ここに置くのは
その保険。

## `bubic-cpu-trace.patch`

BubiC (`~/dev/_Emu/BubiC-8801MA`) の `src/vm/z80.cpp` に、命令ごとの
T-state 累計を吐く trace を足す。`scripts/tstate_diff.py` の入力を作るのが
目的で、狙いと結果は `docs/develop/MEMORY_WAIT_STATES.md` §6 にある。

```bash
cd ~/dev/_Emu/BubiC-8801MA
git apply /path/to/Bubilator88/scripts/patches/bubic-cpu-trace.patch
cd build && cmake --build .
```

有効化は `BUBIC_CPU_TRACE=1`、出力先は `BUBIC_CPU_TRACE_FILE`、行数上限は
`BUBIC_CPU_TRACE_LIMIT`。既存の `BUBIC_PIO_LOG` と同じ作法にしてある。

`total_icount` は `USE_DEBUGGER` 下でしか更新されないが、`pc8801.h:267` で
無条件に `#define` されているので追加のビルド設定は要らない。

パッチが当たらなくなったら (上流が `z80.cpp` を触った等)、当てる先は
`Z80::run_one_opecode()` の冒頭 —— `after_ei` の分岐より前 —— で、
`is_primary` のときだけ `total_icount` を出力する、という 1 点だけ。
