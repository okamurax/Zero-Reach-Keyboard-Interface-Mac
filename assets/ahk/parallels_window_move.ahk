#Requires AutoHotkey v2.0
#SingleInstance Force

; Karabiner経由でMac側から送られてくるトリガーを処理する。
;   Ctrl+Win+1 = 左ディスプレイに移動+最大化 (F13+1 相当)
;   Ctrl+Win+2 = 右ディスプレイに移動+最大化 (F13+2 相当、インデックス3想定・足りなければ最後)
;   Ctrl+Win+3 = 1200x750 固定リサイズ・位置維持 (F13+C 相当)
;   Ctrl+Win+4 = MS-IME OFF (英数モード)      (英数単押し相当)
;   Ctrl+Win+5 = MS-IME ON  (ひらがなモード)  (英数ダブルタップ相当)
;   Ctrl+Win+6 = 中央ディスプレイ(Mac本体)に移動+最大化 (F13+X 相当)

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
    WinMove(m.L, m.T, m.R - m.L, m.B - m.T, hwnd)
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
^#3::ModerateResize()
^#4::Send("{vkF2}{vk19}")  ; 一旦IME ONにしてから半角/全角トグルでOFF (常にIME OFFで確定)
^#5::Send("{vkF2}")        ; VK_DBE_HIRAGANA (常にIME ON + ひらがな)
^#6::MoveToMonitor(2)
