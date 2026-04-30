#Requires AutoHotkey v2.0
#SingleInstance Force

; Karabiner経由でMac側から送られてくるトリガーを処理する。
;   Ctrl+Win+1 = 左ディスプレイに移動+最大化 (F13+1 相当)
;   Ctrl+Win+2 = 右ディスプレイに移動+最大化 (F13+2 相当、インデックス3想定・足りなければ最後)
;   Ctrl+Win+3 = 中央ディスプレイ(Mac本体)に移動+最大化 (F13+C 相当)
;   Ctrl+Win+4 = MS-IME OFF (英数モード)      (英数単押し相当)
;   Ctrl+Win+5 = MS-IME ON  (ひらがなモード)  (英数ダブルタップ相当)
;   Ctrl+Win+6 = 1200x750 固定リサイズ・位置維持 (F13+X 相当)
;   Ctrl+Win+7 = Alt+Right (F13+W 相当 / Explorer/ブラウザ進む)
;   Ctrl+Win+8 = 前タブ (F13+A 相当 / Explorer=Ctrl+Shift+Tab、他=Ctrl+PageUp)
;   Ctrl+Win+9 = 次タブ (F13+S 相当 / Explorer=Ctrl+Tab、他=Ctrl+PageDown)
;   Ctrl+Win+0 = Alt+Left  (F13+Q 相当 / Explorer/ブラウザ戻る)
; ※ F13+F の最小化は Hammerspoon 経由 (hammerspoon://minimizefocused) に移行済み。
;    AHK の WinMinimize は Parallels Coherence では macOS 側で「非表示」扱いとなり
;    Hammerspoon 自作タスクバーから消える問題があったため。
; ※ F13+Q/W は Opt+矢印 だと macOS の単語移動ショートカットと競合し Parallels に届かないため
;    AHKトンネル経由に変更。

; MonitorGetWorkArea は Mac Dock 領域は既に除外した値を返すが、Hammerspoon 自作タスクバー
; (overlayウィンドウ) は Parallels から見えないため認識されない。よって下端のみ手動オフセット。
MAC_TASKBAR_BOTTOM := 38   ; Hammerspoon自作タスクバー (全ディスプレイ共通)

GetSortedMonitors() {
    mons := []
    Loop MonitorGetCount() {
        MonitorGetWorkArea(A_Index, &L, &T, &R, &B)
        mons.Push({L: L, T: T, R: R, B: B})
    }
    n := mons.Length
    i := 1
    while (i < n) {
        j := 1
        while (j <= n - i) {
            if (mons[j].L > mons[j + 1].L) {
                tmp := mons[j]
                mons[j] := mons[j + 1]
                mons[j + 1] := tmp
            }
            j++
        }
        i++
    }
    return mons
}

MoveToMonitor(sortedIdx) {
    global MAC_TASKBAR_BOTTOM
    hwnd := WinExist("A")
    if (!hwnd)
        return
    mons := GetSortedMonitors()
    if (sortedIdx > mons.Length)
        sortedIdx := mons.Length
    if (sortedIdx < 1)
        sortedIdx := 1
    m := mons[sortedIdx]

    if (WinGetMinMax(hwnd) != 0)
        WinRestore(hwnd)
    WinMove(m.L, m.T, m.R - m.L, m.B - m.T - MAC_TASKBAR_BOTTOM, hwnd)
}

ModerateResize() {
    hwnd := WinExist("A")
    if (!hwnd)
        return
    if (WinGetMinMax(hwnd) != 0)
        WinRestore(hwnd)
    WinGetPos(&x, &y, &w, &h, hwnd)
    WinMove(x, y, 1200, 750, hwnd)
}

^#1::MoveToMonitor(1)
^#2::MoveToMonitor(3)
^#3::MoveToMonitor(2)
^#4::Send("{vkF2}{vk19}")  ; 一旦IME ONにしてから半角/全角トグルでOFF (常にIME OFFで確定)
^#5::Send("{vkF2}")        ; VK_DBE_HIRAGANA (常にIME ON + ひらがな)
^#6::ModerateResize()
^#7::Send("!{Right}")  ; F13+W (進む)
^#8::SwitchTabPrev()
^#9::SwitchTabNext()
^#0::Send("!{Left}")   ; F13+Q (戻る)

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

; Excel: Shift+ホイール → 横スクロール (Excel 2016+ は WheelLeft/Right にネイティブ応答)
#HotIf WinActive("ahk_exe EXCEL.EXE")
+WheelUp::Send("{WheelLeft}")
+WheelDown::Send("{WheelRight}")
#HotIf
