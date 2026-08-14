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
- `movetodisplay?idx=N` — N番目のディスプレイ (左から順) に移動+最大化。`fullFrame` ベース計算で Dock auto-hide 状態に依存しない。自作タスクバーの高さは `taskbar.lua` の `BAR_H` を直接参照するので URL には渡さない (値の二重管理を避けるため)。`idx` がディスプレイ数を超える場合は最右にクランプする (2画面では `idx=1` の「中央」も最右に丸まる)。
- `prevwindow` — 直前まで手前にあったウィンドウへフォーカス (Win 風 Alt+Tab の交互トグル)。状態を持たず毎回 `orderedWindows` の重なり順を読むだけなので、Parallels のフォーカス固着の影響を受けにくい。
- `resizemoderate` — 1200x750 固定リサイズ (位置維持)。
- `minimizedisplay` — アクティブウィンドウを最小化。Finder のみ app:hide() に分岐 (Finder は win:minimize() で AX 列挙から落ちて自作タスクバーから消える特殊仕様のため)。現状どのキーにも未割当 (F13+F は「更新」へ変更済み)、手動 URL 起動用に残置。

**Karabiner からの起動は URL ではなく F16〜F20 の送出**で行う (`hs.hotkey` で受ける)。以前は `open -g 'hammerspoon://...'` を叩いており、1押下ごとに sh と open の fork + LaunchServices への IPC が走っていた。連打時のプロセス生成が WindowServer を固める一因だったため経路ごと廃止した。F16 以降を選んだのは macOS 標準ホットキーが F14/F15 までしか使っておらず、かつ Parallels が F14 系以降をグラブしないため。修飾キーは付けない (Karabiner の `from` が物理修飾キーを素通しするため、修飾付きだとホットキーの完全一致から外れて不発になる)。URL ハンドラは手動起動用に残してあり、`karabiner.json` を戻すだけで旧方式に復帰できる。

| F13レイヤー | 送出キー | 処理 |
|---|---|---|
| `V` | F16 | `prevwindow` |
| `1` | F17 | `movetodisplay?idx=0` |
| `2` | F18 | `movetodisplay?idx=2` |
| `C` | F19 | `movetodisplay?idx=1&dockw=61` |
| `X` | F20 | `resizemoderate` |

### 自作Win風タスクバー (`taskbar.lua`)
画面下に貼り付くタスクバーをディスプレイごとに表示。

- **左クリック** — 常に「最前面 + フォーカス」(最小化トグルはしない。最小化すると AX 列挙から落ちてバーから消えるアプリが多いため)。最小化/hide 中なら復元してから最前面化。
- **右側 ×** — クローズ。
- **空き領域ダブルクリック** — 「デスクトップを表示」をトグル (`hs.spaces.toggleShowDesktop`、キー送出を使わない)。最小化と違いウィンドウは非最小化のまま退避するのでバーから消えない。Mission Control は F13+R に残置。
- 並び順はウィンドウID (生成順) で固定 (フォーカスしてもアクティブ窓が左へ飛ばない)。アクティブ項目の色付けはなし。

差分 render + アイコンキャッシュで負荷軽減。windowMoved は購読せず、windowFilter の取りこぼし (Adobe / Parallels) とディスプレイ間移動は 8 秒のフォールバックポーリング + focus/title イベントで拾う。各イベントは 200ms の debounce でまとめ、連射が続いて発火し続ける場合もバースト開始から最長 1 秒で必ず 1 回 flush する (starvation 防止)。

### マウスボタン入れ替え (Chrome 限定)
中ボタンと右クリックを入れ替え。トラックパッド対応のため Karabiner ではなく Hammerspoon (`hs.eventtap`) で実装。

トラックパッドの中クリックは別アプリ **MiddleClick** が供給している。その **"Tap to click" は必ず OFF** (3本指の物理押し込みを要求) にすること。ON だと3本指タップで中クリックが合成され、文字入力中に手のひらが3点触れただけで Chrome にコンテキストメニューが暴発する。macOS 側の「タップでクリック」設定とは無関係に発火するので OS 側では止められない。

### 自己復旧・死活監視
この構成は「壊れる」より「静かに効かなくなる」失敗が多いため、3つの watchdog を置いている。

- **eventtap の再有効化** (1秒間隔) — メインスレッドが詰まると macOS がクリック変換のタップを無効化する。`CGEventTapIsEnabled` で検出して復帰させる。Hammerspoon 自身は自動再有効化しないため、この間隔がそのまま「無言で死んでいる最大時間」になる。
- **タスクバーの停止検出** (30秒間隔) — windowFilter 購読・ポーリング・各 watcher には生存確認 API が無いので、機構ごとではなく「描画が更新され続けているか」(`taskbar.secondsSinceRefresh`) という結果側の一点で見る。止まっていれば watcher 一式を作り直す。
- **VM 内 AHK の死活監視** (30秒間隔) — AHK が黙って落ちると Windows 側のトンネルが全滅する。AHK が `\\Mac\Home\.zero-reach-ahk-heartbeat` を30秒ごとに更新し、途絶を Hammerspoon が通知する。**Parallels の「Mac のフォルダを Windows と共有」が有効である必要がある**。ファイルが存在しない場合は「未配線」とみなして黙る (誤報を出さない)。判定は Parallels が前面のときだけ行うので、VM 停止中や Mac 作業中には鳴らない。

AX の応答待ちは `hs.window.timeout(1)` で1秒に制限している。既定 (約6秒) のままだと、AX が詰まったアプリ1つでメインスレッドが数秒止まり、上記のタップ無効化を誘発するため。

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
| `1` | `.` (ピリオド) |
| `3` | Backspace |
| `4` | Enter |
| `W` | Cmd+F14 (Spotlight、Mac/Parallels両対応) |
| `F13` (= 英数+F13) | かな (Parallels時: Win-IME ON) |
| 単押し | 英数 (Parallels時: Win-IME OFF) |

### F13レイヤー

| キー | Mac 前面 | Parallels 前面 (Coherence Winアプリ) |
|---|---|---|
| `H` `J` `K` `L` | ← ↓ ↑ → | (同左) |
| `V` | 直前のウィンドウへフォーカス (Win風 Alt+Tab) | (同左) |
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
| `Backspace` | Forward Delete | (同左) |
| `G` | Opt+Shift+G (Chrome 拡張用) | (同左) |
| `Z` | Opt+Shift+Z (Chrome 拡張用) | (同左) |

#### F13 記号サブレイヤー (Mac/Parallels 共通)

ホームポジション周辺で JIS の記号を直接打つためのサブレイヤー。出力は Mac / Parallels 同一。

| キー | 出力 | 内訳 (JIS) |
|---|---|---|
| `N` | `(` | Shift+8 |
| `M` | `)` | Shift+9 |
| `,` | `<` | Shift+, |
| `.` | `>` | Shift+. |
| `Y` | `¥` | international3 |
| `U` | `"` | Shift+2 |
| `I` | `'` | Shift+7 |
| `O` | `#` | Shift+3 |
| `P` | `%` | Shift+5 |
| `:` | `&` | Shift+6 |
| `-` | `@` | open_bracket |
| `/` | `!` | Shift+1 |
| `[` | `^` | equal_sign |
| `]` | `$` | Shift+4 |
| `_` | `\|` | Shift+international3 |

### その他

| 操作 | 機能 |
|---|---|
| Cmd+C ダブルタップ | 行選択+コピー (500ms以内) |
| 左Cmd ダブルタップ (Mac) | Cmd+Shift+V (Clipy) |
| 左Cmd ダブルタップ (Parallels前面) | Cmd+Shift+V (Mac側 Clipy) |
| 左Cmd 修飾時 (Parallels前面) | 左Ctrl として送出 |
| 左Ctrl(=Cmd) + I | F7 (カタカナ変換)。日本語入力モード中のみ。英数モードでは素の Cmd+I が通る (Finder の「情報を見る」等) |

## セットアップ

```sh
git clone https://github.com/okamurax/Zero-Reach-Keyboard-Interface-Mac.git
cd Zero-Reach-Keyboard-Interface-Mac
cp -R karabiner/*   ~/.config/karabiner/
cp -R hammerspoon/* ~/.hammerspoon/
```

**symlink にしないこと。** Karabiner-Elements は GUI を操作するたび `~/.config/karabiner/karabiner.json` を書き戻して JSON を再整形するため、symlink だとリポジトリのファイルが直接上書きされて意図しない差分が入る。リポジトリ → 実行先は常にコピーで配布し、変更はリポジトリ側で編集してから配り直す。

その後:
1. Karabiner-Elements の GUI から complex_modifications の rule を有効化
2. Hammerspoon を再起動 (`init.lua` 自動読込)
3. (Parallels Windows 連携を使う場合) VM 内で `karabiner/assets/ahk/parallels_window_move.ahk` を AutoHotkey v2 で実行

AHK を起動したら、Mac 側に `~/.zero-reach-ahk-heartbeat` が生成されるか確認する。生成されていれば死活監視が配線できている。生成されない場合は Parallels の共有フォルダ (`\\Mac\Home`) が無効なので、AHK 自体は動くが停止を検知できない。

## 前提環境

- macOS (Apple Silicon で確認)
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/)
- [Hammerspoon](https://www.hammerspoon.org/)
- (任意) Parallels Desktop + Windows VM + [AutoHotkey v2](https://www.autohotkey.com/)

## 関連

- 移行元 (Windows + AHK): [okamurax/Zero-Reach-AHK](https://github.com/okamurax/Zero-Reach-AHK)
