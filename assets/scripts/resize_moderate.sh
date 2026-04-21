#!/bin/bash
osascript <<'APPLESCRIPT'
use framework "AppKit"

set mainScreen to current application's NSScreen's mainScreen()
set visFrame to mainScreen's visibleFrame()

-- Dock・メニューバーを除いた領域のサイズ
set vw to item 1 of item 2 of visFrame as integer
set vh to item 2 of item 2 of visFrame as integer

-- 75%幅、75%高さ（位置はそのまま）
set winW to (vw * 75 div 100)
set winH to (vh * 75 div 100)

tell application "System Events"
    tell first application process whose frontmost is true
        set size of first window to {winW, winH}
    end tell
end tell
APPLESCRIPT
