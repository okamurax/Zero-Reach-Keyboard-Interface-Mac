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

-- Cocoa座標（左下原点）→ AppleScript座標（左上原点）に変換
set topY to totalH - vy - vh

-- Windowsタスクバー分を引く（約48px、合わなければ調整）
set taskbarH to 48
set adjustedH to vh - taskbarH

tell application "System Events"
    tell first application process whose frontmost is true
        set position of first window to {vx, topY}
        set size of first window to {vw, adjustedH}
    end tell
end tell
APPLESCRIPT
