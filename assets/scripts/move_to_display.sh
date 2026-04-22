#!/bin/bash
# Usage: move_to_display.sh <screen_index> [dock_right] [taskbar_bottom_px]
# screen_index:       0-based, screens sorted left-to-right by x-coordinate
# dock_right:         if "dock_right", subtract Dock width from the right side (else "" / "none")
# taskbar_bottom_px:  pixels to subtract from bottom (for Parallels Coherence Windows taskbar)

SCREEN_INDEX="${1:-0}"
DOCK_RIGHT="${2:-}"
TASKBAR_BOTTOM="${3:-0}"

osascript - "$SCREEN_INDEX" "$DOCK_RIGHT" "$TASKBAR_BOTTOM" <<'APPLESCRIPT'
use framework "AppKit"

on run argv
    set targetIndex to (item 1 of argv) as integer
    set dockFlag to ""
    set taskbarBottom to 0
    if (count of argv) > 1 then set dockFlag to item 2 of argv
    if (count of argv) > 2 then set taskbarBottom to (item 3 of argv) as integer

    set allScreens to current application's NSScreen's screens()
    set screenCount to count of allScreens

    -- Collect screen info
    set screenList to {}
    repeat with i from 1 to screenCount
        set scr to item i of allScreens
        set frm to scr's frame()
        set xPos to (item 1 of item 1 of frm) as integer
        set end of screenList to {idx:i, xPosition:xPos}
    end repeat

    -- Bubble sort by x position (left to right)
    repeat with i from 1 to (count of screenList) - 1
        repeat with j from 1 to (count of screenList) - i
            if xPosition of item j of screenList > xPosition of item (j + 1) of screenList then
                set temp to item j of screenList
                set item j of screenList to item (j + 1) of screenList
                set item (j + 1) of screenList to temp
            end if
        end repeat
    end repeat

    -- Clamp index
    if targetIndex ≥ screenCount then set targetIndex to screenCount - 1
    if targetIndex < 0 then set targetIndex to 0

    set targetScreenIdx to idx of item (targetIndex + 1) of screenList
    set targetScreen to item targetScreenIdx of allScreens

    -- Coordinate conversion: Cocoa uses main screen's full height as reference
    set mainScreen to current application's NSScreen's mainScreen()
    set mainFrame to mainScreen's frame()
    set totalH to (item 2 of item 2 of mainFrame) as integer

    -- Visible frame of target screen (excludes Dock & menu bar)
    set visFrame to targetScreen's visibleFrame()
    set screenFrame to targetScreen's frame()
    set vx to (item 1 of item 1 of visFrame) as integer
    set vy to (item 2 of item 1 of visFrame) as integer
    set vw to (item 1 of item 2 of visFrame) as integer
    set vh to (item 2 of item 2 of visFrame) as integer

    -- Subtract Dock width from right side if requested
    if dockFlag = "dock_right" then
        set fullW to (item 1 of item 2 of screenFrame) as integer
        set dockW to fullW - vw - (vx - ((item 1 of item 1 of screenFrame) as integer))
        set vw to vw - dockW
    end if

    -- Cocoa (bottom-left origin) -> AppleScript (top-left origin)
    -- IMPORTANT: compute topY BEFORE shrinking vh, so the window's TOP stays
    -- at the visible frame top and only the BOTTOM moves up by taskbarBottom.
    set topY to totalH - vy - vh

    -- Subtract Windows taskbar height from bottom (Parallels Coherence Mode)
    if taskbarBottom > 0 then
        set vh to vh - taskbarBottom
    end if

    tell application "System Events"
        tell first application process whose frontmost is true
            set position of first window to {vx, topY}
            set size of first window to {vw, vh}
        end tell
    end tell
end run
APPLESCRIPT
