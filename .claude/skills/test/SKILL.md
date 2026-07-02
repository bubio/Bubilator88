---
name: test
description: EmulatorCore のユニットテストスイート (swift test) を実行して結果を報告する。EmulatorCore/Sources を変更したあとの動作確認に使う。
---

EmulatorCore のユニットテストスイートを実行して結果を報告せよ。

```bash
cd Packages/EmulatorCore && swift test 2>&1
```

テスト失敗時は失敗したテスト名と原因を分析。全パス時はテスト数を報告。
