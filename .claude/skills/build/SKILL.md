---
name: build
description: Xcode プロジェクト全体 (Bubilator88.xcodeproj) をビルドしてエラーを報告する。Swift コード変更後の全体ビルド確認に使う。
---

Bubilator88 プロジェクト全体をビルドしてエラーを報告せよ。

```bash
xcodebuild -scheme Bubilator88 -configuration Debug build 2>&1 | tail -30
```

ビルド失敗時はエラーを分析して修正を提案。成功時は "Build Succeeded" を確認。
