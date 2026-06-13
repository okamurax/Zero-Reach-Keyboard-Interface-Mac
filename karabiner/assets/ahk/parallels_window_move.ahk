#Requires AutoHotkey v2.0
#SingleInstance Force

; Karabiner経由でMac側から送られてくるトリガーを処理する。
; ※ F13+1/2/C のディスプレイ間移動は AHK(Ctrl+Win+1/2/3)を廃止し Hammerspoon に一本化した。
;    VM本体コンソール窓に触れた後 Parallels へのキー配送が詰まりコヒーレンス窓が動かなくなる
;    固着があったため。HS の focusedWindow+setFrame で Mac/コヒーレンス/VM本体すべて直接移動する。
;   Ctrl+Win+4 = MS-IME OFF (英数モード)      (英数単押し相当)
;   Ctrl+Win+5 = MS-IME ON  (ひらがなモード)  (英数ダブルタップ相当)
;   Ctrl+Win+6 = 1200x750 固定リサイズ・位置維持 (F13+X 相当)
;   Ctrl+Win+7 = Alt+Right (F13+W 相当 / Explorer/ブラウザ進む)
;   Ctrl+Win+8 = 前タブ (F13+A 相当 / Explorer=Ctrl+Shift+Tab、他=Ctrl+PageUp)
;   Ctrl+Win+9 = 次タブ (F13+S 相当 / Explorer=Ctrl+Tab、他=Ctrl+PageDown)
;   Ctrl+Win+0 = Alt+Left  (F13+Q 相当 / Explorer/ブラウザ戻る)
; ※ 最小化は Hammerspoon 側 (hammerspoon://minimizedisplay) に実装あり。
;    AHK の WinMinimize は Parallels Coherence では macOS 側で「非表示」扱いとなり
;    Hammerspoon 自作タスクバーから消える問題があったため AHK では扱わない。
;    現状この URL はどのキーにも割り当てていない (F13+F は「更新」に再割当て済み)。
;    最小化を使いたい場合は karabiner 側で minimizedisplay へバインドすること。
; ※ F13+Q/W は Opt+矢印 だと macOS の単語移動ショートカットと競合し Parallels に届かないため
;    AHKトンネル経由に変更。

ModerateResize() {
    hwnd := WinExist("A")
    if (!hwnd)
        return
    if (WinGetMinMax(hwnd) != 0)
        WinRestore(hwnd)
    WinGetPos(&x, &y, &w, &h, hwnd)
    WinMove(x, y, 1200, 750, hwnd)
}

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
