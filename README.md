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
- **⌘C / Enter** copies to the clipboard, **⌘S** saves (PNG / JPEG), **Esc** cancels
- Multi-display support, exports at native Retina resolution
- Preferences: hot key, save folder, image format, copy-after-save, launch at login

### Requirements

- macOS 14 (Sonoma) or later, Apple Silicon or Intel
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

"Launch at login" only works when the app runs from the .app bundle in `/Applications`.

### Usage

1. Press ⇧⌘9 (or click the menu bar icon → Take Screenshot)
2. Drag to select an area (or click a window)
3. Annotate with the toolbar on the right; the color button opens color, line width and text size
4. Click Copy or Save in the bar below, or press ⌘C / ⌘S

### Troubleshooting

Diagnostics are written to `~/Library/Logs/Lightshot Alternative.log` (hot key presses, captures, sessions).

### Layout

| File | Role |
| --- | --- |
| `Sources/LightshotAlt/AppDelegate.swift` | Menu bar item, hot key registration, starting a capture |
| `Sources/LightshotAlt/HotKeyManager.swift` | Global hot key via the Carbon API |
| `Sources/LightshotAlt/ScreenCapturer.swift` | Captures every display with ScreenCaptureKit |
| `Sources/LightshotAlt/CaptureSession.swift` | One overlay window per display, copy and save |
| `Sources/LightshotAlt/OverlayView.swift` | Selection, annotations, toolbars, export |
| `Sources/LightshotAlt/Annotation.swift` | Annotation drawing |
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
- **⌘C / Enter** でクリップボードへコピー、**⌘S** で保存（PNG / JPEG）、**Esc** でキャンセル
- マルチディスプレイ対応、Retina 解像度で書き出し
- 設定: ホットキー、保存先フォルダ、画像形式、保存時にコピーも行う、ログイン時に起動

### 必要環境

- macOS 14 (Sonoma) 以降、Apple Silicon または Intel
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

「ログイン時に起動」は `/Applications` に入れた .app から起動している場合のみ機能します。

### 使い方

1. ⇧⌘9（またはメニューバーのアイコン → Take Screenshot）
2. ドラッグで範囲を選択（ウィンドウをクリックでも可）
3. 右側のツールバーで注釈を描く。色ボタンから色・線幅・文字サイズを変更
4. 下のバーの「コピー」または「保存」、もしくは ⌘C / ⌘S

### トラブルシューティング

`~/Library/Logs/Lightshot Alternative.log` に診断ログ（ホットキー押下、撮影、セッション）が記録されます。

### 構成

| ファイル | 役割 |
| --- | --- |
| `Sources/LightshotAlt/AppDelegate.swift` | メニューバー項目、ホットキー登録、撮影の開始 |
| `Sources/LightshotAlt/HotKeyManager.swift` | Carbon API によるグローバルホットキー |
| `Sources/LightshotAlt/ScreenCapturer.swift` | ScreenCaptureKit で全ディスプレイを撮影 |
| `Sources/LightshotAlt/CaptureSession.swift` | ディスプレイごとのオーバーレイウィンドウ、コピー・保存 |
| `Sources/LightshotAlt/OverlayView.swift` | 範囲選択・注釈・ツールバー・書き出し |
| `Sources/LightshotAlt/Annotation.swift` | 注釈の描画 |
| `Sources/LightshotAlt/PreferencesWindowController.swift` | 設定画面 |
| `scripts/generate-icon.swift` | アプリアイコンとメニューバーアイコンの生成 |
| `scripts/make-signing-cert.sh` | 自己署名の署名証明書の作成 |
| `build.sh` | .app の組み立て・署名・パッケージング |

### ライセンス

MIT
