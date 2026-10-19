# Lightshot Alternative

[English](#english) | [日本語](#日本語)

---

## English

A Lightshot-style screenshot tool for macOS that runs natively on Apple Silicon.
No Rosetta 2, no third-party dependencies: just Swift, AppKit and ScreenCaptureKit.

### Features

- Menu bar app. Start a capture with a global hot key (default **⇧⌘9**, configurable)
- Freezes the screen, then drag to select an area, or click a window to select it
- Resize the selection with handles, move it by dragging, nudge by 1 px with the arrow keys (⇧+arrows to resize)
- Annotation tools: pen / marker / line / arrow / rectangle / text, with color, line width and text size; undo (⌘Z)
- Annotations stay editable: click one to select it, drag to move, drag the end points of a line / arrow or the corners of a rectangle to reshape, double-click text to edit it, change its color / width / size from the palette, Delete to remove, arrow keys to nudge
- **⌘C / Enter** copies to the clipboard, **⌘S** saves (PNG / JPEG), **Esc** cancels
- Multi-display support, exports at native Retina resolution
- Preferences: hot key, save folder, image format, copy-after-save, launch at login
- **Screen recording** with a second hot key (default **⇧⌘0**): select an area the same way, press ↩ to start, press the hot key again, press Esc, or click the red timer in the menu bar to stop. Saved as .mp4 (H.264 + AAC) in the save folder
  - Audio: system audio, microphone, both mixed together, or mute
  - Show or hide the cursor; optionally ask where to save each recording
  - While recording, everything outside the recorded area is dimmed (the dimming is not captured)
  - Options are in Preferences under "Recording"

### Requirements

- macOS 15 (Sequoia) or later
- Apple Silicon. The code has no architecture-specific parts and `./build.sh universal` produces an arm64 + x86_64 binary, but Intel Macs are untested; the default build and the .dmg are arm64 only
- Xcode (Command Line Tools are enough) to build

### Build and install

```sh
./build.sh            # builds build/Lightshot Alternative.app
./build.sh run        # build and launch
./build.sh install    # build, copy to /Applications and launch
./build.sh dmg        # build a drag-and-drop installer (build/Lightshot-Alternative-<version>.dmg)
./build.sh universal  # universal (arm64 + x86_64) binary
swift test            # tests for the export pipeline
```

#### Code signing (do this once)

Run `./scripts/make-signing-cert.sh` once before building. It creates a self-signed certificate
named "Lightshot Alternative Dev" in your login keychain, and `build.sh` uses it automatically.
With a fixed certificate the Screen Recording permission survives rebuilds. With ad-hoc signing the
signature changes on every build and macOS silently drops the permission (the toggle in System
Settings still looks on). If that happens, toggle it off and on again and relaunch the app.

#### Installing from the .dmg

Open the .dmg created by `./build.sh dmg` and drag "Lightshot Alternative" onto the "Applications" link next to it.

On another Mac, the app is not notarized, so the first launch warns that the developer cannot be verified.
Click "Open Anyway" at the bottom of **System Settings → Privacy & Security**, or remove the quarantine attribute:

```sh
xattr -dr com.apple.quarantine "/Applications/Lightshot Alternative.app"
```

#### Screen Recording permission

The first capture asks for Screen Recording access. Enable "Lightshot Alternative" under
**System Settings → Privacy & Security → Screen & System Audio Recording**, then relaunch the app.

Recording with the microphone additionally asks for Microphone access the first time.

"Launch at login" only works when the app runs from the .app bundle in `/Applications`.

### Usage

1. Press ⇧⌘9 (or click the menu bar icon → Take Screenshot)
2. Drag to select an area (or click a window)
3. Annotate with the toolbar on the right; the color button opens color, line width and text size
4. Click Copy or Save in the bar below, or press ⌘C / ⌘S

To record: press ⇧⌘0, select the area, press ↩. The menu bar shows a red dot with the elapsed time; press ⇧⌘0 again, press Esc, or choose Stop Recording to finish.

### Troubleshooting

Logging is off by default. To diagnose a problem, enable it and relaunch the app; lines are written to `~/Library/Logs/Lightshot Alternative.log` (hot key presses, captures, sessions).

```sh
defaults write com.hayato.lightshot-alternative debugLogging -bool true   # enable
defaults delete com.hayato.lightshot-alternative debugLogging             # disable
```

### Layout

| File | Role |
| --- | --- |
| `Sources/LightshotAlt/AppDelegate.swift` | Menu bar item, hot key registration, starting a capture |
| `Sources/LightshotAlt/HotKeyManager.swift` | Global hot key via the Carbon API |
| `Sources/LightshotAlt/ScreenCapturer.swift` | Captures every display with ScreenCaptureKit |
| `Sources/LightshotAlt/CaptureSession.swift` | One overlay window per display, copy and save |
| `Sources/LightshotAlt/OverlayView.swift` | Selection, annotations, toolbars, export |
| `Sources/LightshotAlt/Annotation.swift` | Annotation drawing |
| `Sources/LightshotAlt/ScreenRecorder.swift` | Screen / audio recording with SCStream and AVAssetWriter |
| `Sources/LightshotAlt/AudioPipeline.swift` | Converts and mixes system audio and microphone |
| `Sources/LightshotAlt/RecordingDimWindow.swift` | Click-through overlay that dims everything outside the recorded area |
| `Sources/LightshotAlt/PreferencesWindowController.swift` | Preferences window |
| `scripts/generate-icon.swift` | Generates the app icon and the menu bar icon |
| `scripts/make-signing-cert.sh` | Creates the self-signed signing certificate |
| `build.sh` | Assembles, signs and packages the .app |

### License

MIT

---

## 日本語

Apple Silicon ネイティブで動く、macOS 用の Lightshot 風スクリーンショットツールです。
Rosetta 2 に依存せず、Swift + AppKit + ScreenCaptureKit だけで作られています（外部依存なし）。

### 機能

- メニューバー常駐。グローバルホットキー（既定 **⇧⌘9**、設定で変更可）で撮影開始
- 画面をフリーズして、ドラッグで範囲選択。ウィンドウをクリックするとそのウィンドウを選択
- 選択範囲はハンドルでリサイズ、内側をドラッグで移動、矢印キーで 1px 移動（⇧+矢印でサイズ変更）
- 注釈ツール: ペン / マーカー / 直線 / 矢印 / 矩形 / テキスト、色・線幅・文字サイズの変更、取り消し（⌘Z）
- 注釈は後から編集可能: クリックで選択、ドラッグで移動、直線・矢印の端点や矩形の四隅をドラッグで変形、テキストはダブルクリックで再編集、パレットから色・線幅・サイズを変更、Delete で削除、矢印キーで1px移動
- **⌘C / Enter** でクリップボードへコピー、**⌘S** で保存（PNG / JPEG）、**Esc** でキャンセル
- マルチディスプレイ対応、Retina 解像度で書き出し
- 設定: ホットキー、保存先フォルダ、画像形式、保存時にコピーも行う、ログイン時に起動
- **画面録画**（既定ホットキー **⇧⌘0**）: 同じ操作で範囲を選び ↩ で開始、もう一度ホットキーを押すか、Esc、またはメニューバーの赤いタイマーをクリックで停止。保存先フォルダに .mp4（H.264 + AAC）で保存
  - 音源: システム音声 / マイク / システム音声＋マイク（ミックス） / ミュート
  - カーソルの表示・非表示、録画ごとに保存先を尋ねるかどうか
  - 録画中は録画範囲以外が暗く表示されます（暗転は録画には映りません）
  - オプションは設定画面の「Recording」で変更

### 必要環境

- macOS 15 (Sequoia) 以降
- Apple Silicon。コードにアーキテクチャ依存の部分はなく `./build.sh universal` で arm64 + x86_64 のバイナリを作れますが、Intel Mac では未検証です。既定のビルドと .dmg は arm64 専用です
- ビルドには Xcode（Command Line Tools だけでも可）

### ビルドとインストール

```sh
./build.sh            # build/Lightshot Alternative.app を作成
./build.sh run        # ビルドして起動
./build.sh install    # ビルドして /Applications にコピーし起動
./build.sh dmg        # ドラッグ＆ドロップ用の .dmg を作成（build/Lightshot-Alternative-<version>.dmg）
./build.sh universal  # arm64 + x86_64 のユニバーサルバイナリ
swift test            # 書き出しパイプラインのテスト
```

#### 署名証明書（最初に一度だけ）

ビルドの前に `./scripts/make-signing-cert.sh` を一度実行してください。ログインキーチェーンに
自己署名の証明書「Lightshot Alternative Dev」を作成し、`build.sh` が自動でそれを使います。
証明書を固定することで、再ビルドしても画面収録の許可が維持されます。アドホック署名だと
ビルドのたびに署名が変わり、出した許可が無効になります（設定のトグルはオンのままに見えます）。
その場合は設定でトグルを一度オフ→オンにしてアプリを再起動すると直ります。

#### .dmg からインストールする

`./build.sh dmg` で作った .dmg を開き、「Lightshot Alternative」を隣の「Applications」へドラッグします。

別の Mac で開く場合、公証されていないため初回に「開発元を確認できない」と警告されます。
**システム設定 → プライバシーとセキュリティ** の下部にある「このまま開く」を押すか、
次のコマンドで隔離属性を外してください。

```sh
xattr -dr com.apple.quarantine "/Applications/Lightshot Alternative.app"
```

#### 画面収録の許可

初回の撮影時に「画面収録」の許可を求められます。
**システム設定 → プライバシーとセキュリティ → 画面収録とシステムオーディオ録音** で
「Lightshot Alternative」を有効にし、アプリを再起動してください。

マイクを使う録画では、初回にマイクの許可も求められます。

「ログイン時に起動」は `/Applications` に入れた .app から起動している場合のみ機能します。

### 使い方

1. ⇧⌘9（またはメニューバーのアイコン → Take Screenshot）
2. ドラッグで範囲を選択（ウィンドウをクリックでも可）
3. 右側のツールバーで注釈を描く。色ボタンから色・線幅・文字サイズを変更
4. 下のバーの「コピー」または「保存」、もしくは ⌘C / ⌘S

録画は ⇧⌘0 → 範囲を選択 → ↩ で開始。メニューバーに赤い●と経過時間が表示され、もう一度 ⇧⌘0、Esc、または Stop Recording で終了します。

### トラブルシューティング

ログは既定でオフです。問題を調べるときだけ以下で有効にしてアプリを再起動すると、`~/Library/Logs/Lightshot Alternative.log` に診断ログ（ホットキー押下、撮影、セッション）が記録されます。

```sh
defaults write com.hayato.lightshot-alternative debugLogging -bool true   # 有効化
defaults delete com.hayato.lightshot-alternative debugLogging             # 無効化
```

### 構成

| ファイル | 役割 |
| --- | --- |
| `Sources/LightshotAlt/AppDelegate.swift` | メニューバー項目、ホットキー登録、撮影の開始 |
| `Sources/LightshotAlt/HotKeyManager.swift` | Carbon API によるグローバルホットキー |
| `Sources/LightshotAlt/ScreenCapturer.swift` | ScreenCaptureKit で全ディスプレイを撮影 |
| `Sources/LightshotAlt/CaptureSession.swift` | ディスプレイごとのオーバーレイウィンドウ、コピー・保存 |
| `Sources/LightshotAlt/OverlayView.swift` | 範囲選択・注釈・ツールバー・書き出し |
| `Sources/LightshotAlt/Annotation.swift` | 注釈の描画 |
| `Sources/LightshotAlt/ScreenRecorder.swift` | SCStream と AVAssetWriter による画面・音声の録画 |
| `Sources/LightshotAlt/AudioPipeline.swift` | システム音声とマイクの変換・ミックス |
| `Sources/LightshotAlt/RecordingDimWindow.swift` | 録画範囲以外を暗くするクリック透過オーバーレイ |
| `Sources/LightshotAlt/PreferencesWindowController.swift` | 設定画面 |
| `scripts/generate-icon.swift` | アプリアイコンとメニューバーアイコンの生成 |
| `scripts/make-signing-cert.sh` | 自己署名の署名証明書の作成 |
| `build.sh` | .app の組み立て・署名・パッケージング |

### ライセンス

MIT
