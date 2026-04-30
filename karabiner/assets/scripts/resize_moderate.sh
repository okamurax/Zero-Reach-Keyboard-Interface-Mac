#!/bin/bash
osascript <<'APPLESCRIPT'
use framework "AppKit"

set mainScreen to current application's NSScreen's mainScreen()
set visFrame to mainScreen's visibleFrame()

-- Dock・メニューバーを除いた領域のサイズ
set vw to item 1 of item 2 of visFrame as integer
set vh to item 2 of item 2 of visFrame as integer

-- 高さは visibleFrame の75%、幅はそこから 4:3 で算出（位置はそのまま）
set winH to (vh * 75 div 100)
set winW to (winH * 4 div 3)

tell application "System Events"
    tell first application process whose frontmost is true
        if (count of windows) > 0 then
            set size of first window to {winW, winH}
        else
            -- Adobe Bridge等、メインウィンドウをAXLayoutAreaとして公開するアプリへのフォールバック
            set la to first UI element whose role is "AXLayoutArea"
            set size of la to {winW, winH}
        end if
    end tell
end tell
APPLESCRIPT
