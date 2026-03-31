#!/bin/bash
osascript <<'APPLESCRIPT'
use framework "AppKit"

set mainScreen to current application's NSScreen's mainScreen()
set screenFrame to mainScreen's frame()
set visFrame to mainScreen's visibleFrame()

-- 画面全体の高さ（座標変換用）
set totalH to item 2 of item 2 of screenFrame as integer

-- Dock・メニューバーを除いた領域
set vx to item 1 of item 1 of visFrame as integer
set vy to item 2 of item 1 of visFrame as integer
set vw to item 1 of item 2 of visFrame as integer
set vh to item 2 of item 2 of visFrame as integer

-- 75%幅、85%高さで中央配置
set winW to (vw * 75 div 100)
set winH to (vh * 75 div 100)
set winX to vx + ((vw - winW) div 2)

-- Cocoa座標（左下原点）→ AppleScript座標（左上原点）に変換
set topY to totalH - vy - vh
set winY to topY + ((vh - winH) div 2)

tell application "System Events"
    tell first application process whose frontmost is true
        set position of first window to {winX, winY}
        set size of first window to {winW, winH}
    end tell
end tell
APPLESCRIPT
