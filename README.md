# Zero-Reach Keyboard Interface Mac

Karabiner-Elements + Hammerspoon による macOS キーボードカスタマイズ。
[Zero-Reach-AHK](https://github.com/okamurax/Zero-Reach-AHK) (Windows + AutoHotkey) の Mac 移植版。

## 設計思想

**Zero-Reach** — 手をホームポジションから離さない。
矢印・タブ操作・ウィンドウ管理など頻繁に使う機能を、Tab キー / 英数キー (= F13) を保持しながら別キーで発火する **レイヤー方式** に集約し、ホームポジション周辺で完結させる。

## 構成

- **Karabiner-Elements** — キー再定義の本体 (`karabiner/`)
- **Hammerspoon** — ウィンドウ管理 / 自作 Win 風タスクバー / Parallels 連携 (`hammerspoon/`)
- **AutoHotkey v2** (Parallels VM 内) — Windows アプリ向け companion スクリプト (`karabiner/assets/ahk/parallels_window_move.ahk`)

3者は `hammerspoon://` URL や `Ctrl+Cmd+数字` ホットキーを経由して連携する (Karabiner → Parallels → VM内AHK の経路で Windows アプリを操作)。

## 移行元 (Zero-Reach-AHK) からの主な変更点

| 項目 | Win (AHK) | Mac (本リポ) |
|---|---|---|
| メインレイヤーキー | 右Shift | F13 (= 英数キーを物理リマップ) |
| サブレイヤーキー | 無変換 | 英数 (= Tabキーを物理リマップ、`tab_held` 変数) |
| ウィンドウ操作 | AHK 直接 | Hammerspoon URL handler 経由 |
| タスクバー | Windows標準 / uBar | Hammerspoon 自作 (`taskbar.lua`) |
| Parallels内 Windowsアプリ操作 | (該当なし) | VM内に AHK companion 常駐、Karabiner→Hammerspoon→AHK で操作トンネリング |
| IME 切替 | 無変換 単押し → IME OFF | 英数 単押し → 英数 / 英数+F13 → かな (Parallels時は Win-IME ON/OFF に分岐) |
| Cmd/Ctrl の関係 | (Win単独) | macOS 標準動作 ⇔ Parallels前面時は左Cmdを左Ctrl化する分岐 |

## 機能

### レイヤー
- **英数(Tab)レイヤー** — Tab を保持しながら他キー押下で発火。単押しは英数キー / 英数+F13 でかな切替 (Parallels前面時は Win-IME ON/OFF 動作)。かな切替は Karabiner 側で HID レベル出力する (Hammerspoon の合成キー送出は酷使下で不安定なため移行)。
- **F13(英数)レイヤー** — F13 を保持しながら他キー押下で発火。矢印・タブ操作・ウィンドウ移動など多数。

### ウィンドウ管理 (Hammerspoon)
- `movetodisplay?idx=N` — N番目のディスプレイ (左から順) に移動+最大化。`fullFrame` ベース計算で Dock auto-hide 状態に依存しない。
- `resizemoderate` — 1200x750 固定リサイズ (位置維持)。
- `minimizedisplay` — アクティブウィンドウを最小化。Finder のみ app:hide() に分岐 (Finder は win:minimize() で AX 列挙から落ちて自作タスクバーから消える特殊仕様のため)。現状どのキーにも未割当 (F13+F は「更新」へ変更済み)、手動 URL 起動用に残置。

### 自作Win風タスクバー (`taskbar.lua`)
画面下に貼り付くタスクバーをディスプレイごとに表示。

- **左クリック** — 常に「最前面 + フォーカス」(最小化トグルはしない。最小化すると AX 列挙から落ちてバーから消えるアプリが多いため)。最小化/hide 中なら復元してから最前面化。
- **右側 ×** — クローズ。
- **空き領域ダブルクリック** — 「デスクトップを表示」をトグル (`hs.spaces.toggleShowDesktop`、キー送出を使わない)。最小化と違いウィンドウは非最小化のまま退避するのでバーから消えない。Mission Control は F13+R に残置。
- 並び順はウィンドウID (生成順) で固定 (フォーカスしてもアクティブ窓が左へ飛ばない)。アクティブ項目の色付けはなし。

差分 render + アイコンキャッシュで負荷軽減。windowMoved は購読せず 8 秒 poll + focus/title イベントでディスプレイ間移動を追従、windowFilter 取りこぼし対策に 1 秒フォールバック refresh あり。

### マウスボタン入れ替え (Chrome 限定)
中ボタンと右クリックを入れ替え。トラックパッド対応のため Karabiner ではなく Hammerspoon (`hs.eventtap`) で実装。

### その他
- **Cmd+C ダブルタップ** — 500ms 以内に再度 Cmd+C で行選択+コピー。
- **左Cmd ダブルタップ** — Cmd+Shift+V (Clipy 起動)。Parallels 前面でも Mac 側で動く。
- **Parallels 前面時の左Cmd多重役割化** — 単独tapは無効化 (スタートメニュー誤爆防止)、修飾時は左Ctrl化、ダブルtapはClipy。

## リマップ一覧

### 物理キー単位 (simple_modifications)

| 物理キー | 出力 |
|---|---|
| `Backspace` | `Forward Delete` |
| `-` | `[` |
| `[` | `'` |
| `'` | `-` |
| `;` | `Enter` |
| 右`Cmd` | `;` |
| 右`Shift` | `Tab` |
| `Tab` | 英数 (= 英数(Tab)レイヤーのトリガ) |
| 英数 | `F13` (= F13レイヤーのトリガ) |
| かな | `Backspace` |
| 左`Cmd` ⇔ 左`Ctrl` | 役割入れ替え |

### 英数(Tab)レイヤー

| キー | 機能 |
|---|---|
| `Q` | ESC |
| `1` | F12 |
| `2` | F2 |
| `3` | Backspace |
| `4` | Enter |
| `W` | Cmd+F14 (Spotlight、Mac/Parallels両対応) |
| `F13` (= 英数+F13) | かな (Parallels時: Win-IME ON) |
| 単押し | 英数 (Parallels時: Win-IME OFF) |

### F13レイヤー

| キー | Mac 前面 | Parallels 前面 (Coherence Winアプリ) |
|---|---|---|
| `H` `J` `K` `L` | ← ↓ ↑ → | (同左) |
| `Q` | Cmd+[ (戻る) | Alt+Left (Explorer/ブラウザ、AHK経由) |
| `W` | Cmd+] (進む) | Alt+Right (Explorer/ブラウザ、AHK経由) |
| `E` | Cmd+W (タブを閉じる) | (同左) |
| `A` | Ctrl+Shift+Tab (前タブ) | Explorer=Ctrl+Shift+Tab / 他=Ctrl+PgUp (AHK経由) |
| `S` | Ctrl+Tab (次タブ) | Explorer=Ctrl+Tab / 他=Ctrl+PgDn (AHK経由) |
| `D` | Cmd+Shift+T (閉じたタブを再開) | (同左) |
| `F` | Cmd+R (更新) | F5 |
| `R` | Mission Control (`mission_control` キー送出。Parallels問わず Mac 全体) | (同左) |
| `1` | 左ディスプレイに移動+最大化 | (AHK経由で同等処理) |
| `2` | 右ディスプレイに移動+最大化 | (AHK経由で同等処理) |
| `C` | Mac 本体ディスプレイ (中央) に移動+最大化 | (AHK経由で同等処理) |
| `X` | 1200x750 リサイズ (位置維持) | (AHK経由で同等処理) |
| `3` | Cmd+↑ (ドキュメント先頭) | Ctrl+Home |
| `4` | Cmd+↓ (ドキュメント末尾) | Ctrl+End |
| `7` | Cmd+← (行頭) | Home |
| `8` | Cmd+→ (行末) | End |
| `0` | `.` (ピリオド) | (同左) |
| `Backspace` | Forward Delete | (同左) |
| `G` | Opt+Shift+G (Chrome 拡張用) | (同左) |
| `Z` | Opt+Shift+Z (Chrome 拡張用) | (同左) |

### その他

| 操作 | 機能 |
|---|---|
| Cmd+C ダブルタップ | 行選択+コピー (500ms以内) |
| 左Cmd ダブルタップ (Mac) | Cmd+Shift+V (Clipy) |
| 左Cmd ダブルタップ (Parallels前面) | Cmd+Shift+V (Mac側 Clipy) |
| 左Cmd 修飾時 (Parallels前面) | 左Ctrl として送出 |
| 左Ctrl(=Cmd) + I | F7 (カタカナ変換) |

## セットアップ

```sh
git clone https://github.com/okamurax/Zero-Reach-Keyboard-Interface-Mac.git
cd Zero-Reach-Keyboard-Interface-Mac
ln -s "$(pwd)/karabiner"   ~/.config/karabiner
ln -s "$(pwd)/hammerspoon" ~/.hammerspoon
```

その後:
1. Karabiner-Elements の GUI から complex_modifications の rule を有効化
2. Hammerspoon を再起動 (`init.lua` 自動読込)
3. (Parallels Windows 連携を使う場合) VM 内で `karabiner/assets/ahk/parallels_window_move.ahk` を AutoHotkey v2 で実行

## 前提環境

- macOS (Apple Silicon で確認)
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/)
- [Hammerspoon](https://www.hammerspoon.org/)
- (任意) Parallels Desktop + Windows VM + [AutoHotkey v2](https://www.autohotkey.com/)

## 関連

- 移行元 (Windows + AHK): [okamurax/Zero-Reach-AHK](https://github.com/okamurax/Zero-Reach-AHK)
