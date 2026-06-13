#Requires AutoHotkey v2.0
#SingleInstance Force

; Karabiner経由でMac側から送られてくるトリガーを処理する。
; ※ F13+1/2/C の移動と F13+X のリサイズは AHK(Ctrl+Win+1/2/3/6)を廃止し Hammerspoon に一本化した。
;    VM本体コンソール窓に触れた後 Parallels へのキー配送が詰まりウィンドウ操作が効かなくなる
;    固着があったため。HS の focusedWindow+setFrame で Mac/コヒーレンス/VM本体すべて直接処理する。
;   Ctrl+Win+4 = MS-IME OFF (英数モード)      (英数単押し相当)
;   Ctrl+Win+5 = MS-IME ON  (ひらがなモード)  (英数ダブルタップ相当)
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

^#4::Send("{vkF2}{vk19}")  ; 一旦IME ONにしてから半角/全角トグルでOFF (常にIME OFFで確定)
^#5::Send("{vkF2}")        ; VK_DBE_HIRAGANA (常にIME ON + ひらがな)
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
