BootTester でディスクイメージを実行して結果を報告せよ。

引数: $ARGUMENTS

引数なしの場合、N88-BASICコールドブートテスト:
```bash
cd Packages/EmulatorCore && swift run -c release BootTester
```

ディスクパスが指定された場合、600フレーム+スクリーンショット付き:
```bash
cd Packages/EmulatorCore && BOOTTEST_FRAMES=600 BOOTTEST_SCREENSHOT_PATH=/tmp/boottest_result.ppm swift run -c release BootTester "$ARGUMENTS"
```

実行後:
1. 最終状態サマリ（PC, SP, 割り込み状態）を報告
2. テキストVRAMダンプがあれば表示
3. スクリーンショットが生成されたら読み取って画面内容を説明
