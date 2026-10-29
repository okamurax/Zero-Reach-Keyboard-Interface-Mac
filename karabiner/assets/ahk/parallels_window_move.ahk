#Requires AutoHotkey v2.0
#SingleInstance Force

; Karabiner経由でMac側から送られてくるトリガーを処理する。
; ※ F13+1/2/C の移動と F13+X のリサイズは AHK(Ctrl+Win+1/2/3/6)を廃止し Hammerspoon に一本化した。
;    VM本体コンソール窓に触れた後 Parallels へのキー配送が詰まりウィンドウ操作が効かなくなる
;    固着があったため。HS の focusedWindow+setFrame で Mac/コヒーレンス/VM本体すべて直接処理する。
;   Ctrl+F19       = MS-IME OFF (英数単押し)
;   Ctrl+Alt+Win+K = MS-IME ON  (英数+F13、ひらがな)
;   Ctrl+Alt+Win+L = Alt+Right (F13+W / Explorer/ブラウザ進む)
;   Ctrl+Alt+Win+U = 前タブ (F13+A / Explorer=Ctrl+Shift+Tab、他=Ctrl+PageUp)
;   Ctrl+Alt+Win+O = 次タブ (F13+S / Explorer=Ctrl+Tab、他=Ctrl+PageDown)
;   Ctrl+Alt+Win+H = Alt+Left  (F13+Q / Explorer/ブラウザ戻る)
;   (Mac 側の Ctrl+Opt+Cmd が Parallels で Ctrl+Alt+Win になる)
; ※ 最小化は Hammerspoon 側 (hammerspoon://minimizedisplay) に実装あり。
;    AHK の WinMinimize は Parallels Coherence では macOS 側で「非表示」扱いとなり
;    Hammerspoon 自作タスクバーから消える問題があったため AHK では扱わない。
;    現状この URL はどのキーにも割り当てていない (F13+F は「更新」に再割当て済み)。
;    最小化を使いたい場合は karabiner 側で minimizedisplay へバインドすること。
; ※ F13+Q/W は Opt+矢印 だと macOS の単語移動ショートカットと競合し Parallels に届かないため
;    AHKトンネル経由に変更。

; ---------------------------------------------------------------------------
; 死活監視用ハートビート
; このスクリプトが黙って落ちると Windows 側のトンネルが全滅するが、従来は
; 「Windowsだけ効かない」という体感でしか気づけなかった。30秒ごとに Mac 側から
; 見える場所へ時刻を書き、Hammerspoon (init.lua の ahkHeartbeatWatchdog) が
; 更新の途絶を検出して通知する。
;
; 書き込み先の共有名は Parallels の「Mac を Windows と共有」設定で変わり、両者は排他:
;   「すべてのディスク」    → \\Mac\AllFiles\Users\<Macユーザー名>\   (現構成)
;   「ホームフォルダーのみ」→ \\Mac\Home\
; 単一パス決め打ちにすると設定変更で無言の未配線に戻るため、候補を順に試して
; 最初に書けたものを以後使い続ける。
;
; 【経緯】当初 \\Mac\Home 決め打ちだったが、実構成は ShareAllMacDisks=1 で
; \\Mac\Home が存在せず、書き込みが常に失敗していた。Mac 側も「ファイルが無ければ黙る」
; 実装だったため、死活監視は導入以来一度も動いていなかった (2026-08-28 判明)。
;
; 共有フォルダが全滅していてもスクリプト本体を絶対に巻き込まないよう try で握り潰す。
; 全滅時は Mac 側にファイルが現れず、Hammerspoon が「未配線」として通知する。
; ---------------------------------------------------------------------------
HEARTBEAT_CANDIDATES := [
    "\\Mac\AllFiles\Users\shogo\.zero-reach-ahk-heartbeat",
    "\\Mac\Home\.zero-reach-ahk-heartbeat"
]
HeartbeatPath := ""

WriteHeartbeat()                  ; 起動直後に1回書き、配線できているか即確認できるようにする
SetTimer(WriteHeartbeat, 30000)

; 【キー選定の経緯】Ctrl+Opt+Cmd+数字 は Finder の「表示順序」(⌃⌥⌘0〜8) と衝突する。
; コヒーレンスのフォーカス固着で Karabiner が Parallels 前面と誤認したまま送出すると、
; デスクトップの並び順が「追加日」等に化ける (⌃⌥⌘4 で実際に発生)。その前は ⌃⌘数字 を
; 使っておりスタックが有効化された。数字帯は丸ごと放棄し、Mac 側で無害な英字に逃がす。
; 例外として英数 (IME OFF) だけは Ctrl+F19。Alt/Win を含むトンネルだと、Alt 無しのキーを Send した時に
; Alt 単独押し扱いとなり Win11 メモ帳がアクセスキー表示を出したため (vkE8 マスクでは消えなかった)。
^F19::ImeOff()              ; 英数 (IME OFF)
^!#k::Send("{vkF2}")        ; 英数+F13 (IME ON): VK_DBE_HIRAGANA (常にIME ON + ひらがな)
^!#l::Send("!{Right}")  ; F13+W (進む)
^!#u::SwitchTabPrev()   ; F13+A
^!#o::SwitchTabNext()   ; F13+S
^!#h::Send("!{Left}")   ; F13+Q (戻る)

; IME OFF。キー送出 (ひらがな→半角/全角トグル) だと変換中はキーが変換操作として
; 食われて OFF にならないため、IME 窓へ WM_IME_CONTROL(0x283) / IMC_SETOPENSTATUS(0x006) / 0
; を送って開閉状態を直接 OFF にする。
; IME 窓は非表示ウィンドウで AHK の SendMessage だと DetectHiddenWindows が要るため DllCall で送る。
; 送り先はフォーカス中のコントロール基準 (アプリによってはトップレベル窓の IME 窓では効かない)。
; IME 窓が取れない時だけ従来のキー送出に戻す。
; 前面アプリが応答なしだと SendMessage がそこで止まり、AHK の全トンネルが道連れになる
; (「AHK が黙って死んだ」と区別がつかない) ため、SMTO_ABORTIFHUNG 付きで 200ms で打ち切る。
ImeOff() {
    hwnd := WinExist("A")
    try {
        if ctl := ControlGetFocus("A")
            hwnd := ctl
    }
    imeWnd := hwnd ? DllCall("imm32\ImmGetDefaultIMEWnd", "Ptr", hwnd, "Ptr") : 0
    if !imeWnd {
        Send("{vkF2}{vk19}")
        return
    }
    DllCall("user32\SendMessageTimeoutW", "Ptr", imeWnd, "UInt", 0x283, "Ptr", 0x006, "Ptr", 0
        , "UInt", 0x2, "UInt", 200, "Ptr*", 0)
}

SwitchTabPrev() {
    if WinActive("ahk_class CabinetWClass")
        Send("^+{Tab}")
    else
        Send("^{PgUp}")
}

SwitchTabNext() {
    if WinActive("ahk_class CabinetWClass")
        Send("^{Tab}")
    else
        Send("^{PgDn}")
}

WriteHeartbeat() {
    global HEARTBEAT_CANDIDATES, HeartbeatPath

    ; 確定済みのパスがあるならそれだけ叩く (毎回全候補を舐めない)。
    ; 失敗したら共有設定が変わったとみなして確定を捨て、下の再探索に落とす。
    if (HeartbeatPath != "") {
        if WriteHeartbeatTo(HeartbeatPath)
            return
        HeartbeatPath := ""
    }

    for _idx, path in HEARTBEAT_CANDIDATES {
        if WriteHeartbeatTo(path) {
            HeartbeatPath := path
            return
        }
    }
    ; 全候補が全滅 = 共有フォルダが使えない。ここでは何もしない。
    ; Mac 側にファイルが現れないことを Hammerspoon が「未配線」として通知する。
}

; 1候補へ書き込みを試し、成否を返す。
; FileDelete は対象が無いと例外を投げるので個別に try で包む。
; 書けた共有パスを内容にも残す。Mac 側で cat すればどの経路で届いたか即わかる。
WriteHeartbeatTo(path) {
    try {
        FileDelete(path)
    }
    try {
        FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss") . " via " . path, path)
    } catch {
        return false
    }
    return FileExist(path) ? true : false
}
