---
name: regression
description: 15 シナリオの回帰テスト (scripts/regression_compare.py) を実行し、参照スクリーンショットとの pixel 比較結果を報告する。EmulatorCore/Sources を変更したあと、コミット前に必ず実行する。
---

回帰テストを実行して結果を報告せよ。

手順:
1. `/Volumes/CrucialX6` がマウントされているか確認。なければ「テストスイートの外付け SSD (CrucialX6) が未接続です」と報告して中止。
2. `swift build --package-path Packages/EmulatorCore` で BootTester を最新にする。
   **必須。** `regression_compare.py` は `.build/arm64-apple-macosx/debug/BootTester`
   を再ビルドせずそのまま実行するので、これを飛ばすと古いバイナリを測ることになり、
   変更が結果に反映されない (PASS も FAIL も信用できなくなる)。
3. リポジトリルートで `python3 scripts/regression_compare.py` を実行 (全シナリオで数分かかる)。
4. 全 PASS (許容差分内の PASS* を含む) の場合:
   - `touch .claude/.last-regression-pass` でマーカーを更新
   - PASS 数を報告して終了
5. FAIL がある場合:
   - `/Volumes/CrucialX6/temp/regression_compare_latest/fails/<stem>/{ref,new,diff}.ppm` を読んで確認
   - 各 FAIL を分類: **true regression** (クラッシュ/黒画面/表示破壊) → マーカーを更新せず、ship をブロックすべきと報告 / **timing-absorbed** (同じゲーム状態でアニメ位相・進行位置だけ違う) → 許容。
   - true regression が 1 件もなければマーカーを更新する
6. 結果は | Game | Diff% | Classification | Notes | の表で報告。

詳細な判定基準は docs/REGRESSION_CHECK.md と .claude/agents/regression-checker.md を参照。
rom_sweep.py をこの用途に使わないこと (回帰判定の唯一の基準は regression_compare.py)。
