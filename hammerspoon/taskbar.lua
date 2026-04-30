-- 画面下に貼り付くWin風タスクバー
-- ディスプレイごとに「そのディスプレイ上のウィンドウ一覧」を表示し、
-- 左クリックでアクティブ化、右側の×でクローズする。
--
-- 設計メモ:
--   * hs.canvas をディスプレイごとに1枚ずつ作る
--   * hs.window.filter のサブスクリプションで再描画
--   * 1秒のフォールバック refresh は filter が取りこぼす Adobe/Parallels 対策

local M = {}

local BAR_H        = 38
local ITEM_W       = 210
local ITEM_GAP     = 4
local ITEM_PAD     = 6
local CLOSE_W      = 21
local ICON_W       = 21
local FONT_SIZE    = 11
local BG_COLOR     = { red = 0.10, green = 0.10, blue = 0.10, alpha = 0.92 }
local ITEM_BG      = { red = 0.20, green = 0.20, blue = 0.20, alpha = 1.0 }
local ITEM_BG_ACT  = { red = 0.30, green = 0.45, blue = 0.75, alpha = 1.0 }
local ITEM_BG_MIN  = { red = 0.14, green = 0.14, blue = 0.14, alpha = 1.0 }
local TEXT_COLOR   = { white = 0.95 }
local TEXT_MIN     = { white = 0.55 }
local CLOSE_COLOR  = { red = 0.85, green = 0.30, blue = 0.30, alpha = 1.0 }

-- screenId -> { canvas, items = { {win, frame, closeFrame}, ... } }
local bars = {}
local refreshTimer
local windowFilter
local moveDebounce

-- bundleID -> hs.image (false = 取得失敗をキャッシュして再試行を抑制)
local iconCache = {}
local function getAppIcon(bid)
    if not bid or bid == "" then return nil end
    local cached = iconCache[bid]
    if cached == nil then
        cached = hs.image.imageFromAppBundle(bid) or false
        iconCache[bid] = cached
    end
    return cached or nil
end

local function screenIdOf(screen)
    return screen:id()
end

-- ウィンドウがタスクバーに出すべきものか
-- 最小化中もタスクバーに残す (クリックで復元するWin風挙動のため)
-- Hammerspoon自身(canvas)は除外
local function isTaskable(win)
    if not win or not win:isStandard() then return false end
    local app = win:application()
    if not app then return false end
    if app:bundleID() == "org.hammerspoon.Hammerspoon" then return false end
    return true
end

-- ディスプレイ毎にウィンドウをグループ化
local function groupWindowsByScreen()
    local map = {}
    for _, win in ipairs(hs.window.allWindows()) do
        if isTaskable(win) then
            local s = win:screen()
            if s then
                local id = screenIdOf(s)
                map[id] = map[id] or { screen = s, wins = {} }
                table.insert(map[id].wins, win)
            end
        end
    end
    return map
end

-- 1枚のバーを描画
-- 表示状態が前回と完全一致なら canvas を触らずに早期return (差分render)。
local function renderBar(bar, wins)
    local focused = hs.window.focusedWindow()
    local focusedId = focused and focused:id() or nil

    -- 表示対象だけ先に確定 (signature と描画ループで共有)
    local visible = {}
    local x0 = ITEM_PAD
    for _, win in ipairs(wins) do
        if x0 + ITEM_W > bar.w - ITEM_PAD then break end
        local app = win:application()
        local title = win:title() or ""
        if title == "" and app then title = app:name() end
        visible[#visible + 1] = {
            win = win,
            id = win:id(),
            title = title,
            isMin = win:isMinimized(),
            isActive = (win:id() == focusedId),
            app = app,
        }
        x0 = x0 + ITEM_W + ITEM_GAP
    end

    -- signature: barサイズ + 各item状態。前回と同じなら描画スキップ
    local sigParts = { bar.w }
    for _, v in ipairs(visible) do
        sigParts[#sigParts + 1] = v.id .. ":" .. v.title .. ":" ..
            (v.isMin and "m" or "_") .. (v.isActive and "a" or "_")
    end
    local sig = table.concat(sigParts, "|")
    if bar.lastSig == sig then return end
    bar.lastSig = sig

    local canvas = bar.canvas
    canvas:replaceElements()

    -- 背景
    canvas[1] = {
        type = "rectangle",
        action = "fill",
        fillColor = BG_COLOR,
        frame = { x = 0, y = 0, w = bar.w, h = BAR_H },
    }

    bar.items = {}

    local x = ITEM_PAD
    for _, v in ipairs(visible) do
        local win, isActive, isMin, app, title = v.win, v.isActive, v.isMin, v.app, v.title

        local bgColor
        if isMin then bgColor = ITEM_BG_MIN
        elseif isActive then bgColor = ITEM_BG_ACT
        else bgColor = ITEM_BG end

        -- アイテム背景
        canvas[#canvas + 1] = {
            type = "rectangle",
            action = "fill",
            fillColor = bgColor,
            roundedRectRadii = { xRadius = 4, yRadius = 4 },
            frame = { x = x, y = 4, w = ITEM_W, h = BAR_H - 8 },
        }

        -- アイコン
        if app then
            local icon = getAppIcon(app:bundleID())
            if icon then
                canvas[#canvas + 1] = {
                    type = "image",
                    image = icon,
                    frame = { x = x + 4, y = (BAR_H - ICON_W) / 2, w = ICON_W, h = ICON_W },
                }
            end
        end

        -- タイトル
        canvas[#canvas + 1] = {
            type = "text",
            text = title,
            textColor = isMin and TEXT_MIN or TEXT_COLOR,
            textSize = FONT_SIZE,
            textLineBreak = "truncateTail",
            frame = {
                x = x + 4 + ICON_W + 4,
                y = (BAR_H - FONT_SIZE) / 2 - 2,
                w = ITEM_W - ICON_W - CLOSE_W - 12,
                h = FONT_SIZE + 4,
            },
        }

        -- × ボタン
        local closeX = x + ITEM_W - CLOSE_W - 2
        canvas[#canvas + 1] = {
            type = "text",
            text = "×",
            textColor = CLOSE_COLOR,
            textSize = FONT_SIZE + 4,
            textAlignment = "center",
            frame = { x = closeX, y = (BAR_H - FONT_SIZE - 4) / 2 - 2, w = CLOSE_W, h = FONT_SIZE + 8 },
        }

        table.insert(bar.items, {
            win = win,
            x1 = x, x2 = x + ITEM_W - CLOSE_W - 2,
            cx1 = closeX, cx2 = closeX + CLOSE_W,
        })

        x = x + ITEM_W + ITEM_GAP
    end
end

-- バーを必要なら作成、不要なら破棄、全部renderする
local function refresh()
    local grouped = groupWindowsByScreen()

    -- 全ディスプレイに対してバーを出す (ウィンドウが無くても空バーを表示)
    local liveScreens = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local id = screenIdOf(screen)
        liveScreens[id] = true
        if not grouped[id] then
            grouped[id] = { screen = screen, wins = {} }
        end
    end

    -- 物理的に外れたディスプレイのバーだけ破棄
    for id, bar in pairs(bars) do
        if not liveScreens[id] then
            bar.canvas:delete()
            bars[id] = nil
        end
    end

    -- ディスプレイごとに描画
    for id, g in pairs(grouped) do
        local screen = g.screen
        local full = screen:fullFrame()
        local vis = screen:frame()
        -- vis の下端と full の下端の差(=Dock領域の高さ)を避けて、その上にバーを置く
        local dockBottom = (full.y + full.h) - (vis.y + vis.h)
        local barX = full.x
        local barY = full.y + full.h - dockBottom - BAR_H
        local barW = full.w

        local bar = bars[id]
        if not bar then
            local canvas = hs.canvas.new({ x = barX, y = barY, w = barW, h = BAR_H })
            canvas:level(hs.canvas.windowLevels.dock - 1)
            canvas:behavior({ "canJoinAllSpaces", "stationary" })
            canvas:clickActivating(false)
            canvas:mouseCallback(function(_, msg, _, x, y)
                if msg ~= "mouseDown" then return end
                local b = bars[id]
                if not b then return end
                for _, item in ipairs(b.items) do
                    if x >= item.cx1 and x <= item.cx2 then
                        if item.win then item.win:close() end
                        return
                    elseif x >= item.x1 and x <= item.x2 then
                        local win = item.win
                        if not win then return end
                        if win:isMinimized() then
                            -- 最小化中: 復元 + フォーカス
                            win:unminimize()
                            win:focus()
                            win:raise()
                        else
                            local focused = hs.window.focusedWindow()
                            if focused and focused:id() == win:id() then
                                -- アクティブ中: 最小化
                                win:minimize()
                            else
                                -- 非アクティブ: 前面に
                                win:focus()
                                win:raise()
                            end
                        end
                        return
                    end
                end
            end)
            canvas:canvasMouseEvents(true, true, false, false)
            canvas:show()
            bar = { canvas = canvas, w = barW, items = {} }
            bars[id] = bar
        else
            -- ディスプレイ解像度・位置が変わった場合に追従
            bar.canvas:frame({ x = barX, y = barY, w = barW, h = BAR_H })
            bar.w = barW
        end

        renderBar(bar, g.wins)
    end
end

function M.start()
    if windowFilter then return end

    windowFilter = hs.window.filter.new(nil)
    windowFilter:subscribe({
        hs.window.filter.windowCreated,
        hs.window.filter.windowDestroyed,
        hs.window.filter.windowFocused,
        hs.window.filter.windowUnfocused,
        hs.window.filter.windowMinimized,
        hs.window.filter.windowUnminimized,
        hs.window.filter.windowTitleChanged,
    }, function() refresh() end)

    -- windowMoved はドラッグ中に大量発火するので debounce で1回に集約
    windowFilter:subscribe(hs.window.filter.windowMoved, function()
        if moveDebounce then moveDebounce:stop() end
        moveDebounce = hs.timer.doAfter(0.15, refresh)
    end)

    -- filter が取りこぼす環境(Adobe / Parallels)向けの保険
    refreshTimer = hs.timer.doEvery(3, refresh)

    -- ディスプレイ構成変更で全部作り直し
    M._screenWatcher = hs.screen.watcher.new(function()
        for id, bar in pairs(bars) do
            bar.canvas:delete()
            bars[id] = nil
        end
        refresh()
    end):start()

    refresh()
end

function M.stop()
    if refreshTimer then refreshTimer:stop(); refreshTimer = nil end
    if moveDebounce then moveDebounce:stop(); moveDebounce = nil end
    if windowFilter then windowFilter:unsubscribeAll(); windowFilter = nil end
    if M._screenWatcher then M._screenWatcher:stop(); M._screenWatcher = nil end
    for id, bar in pairs(bars) do
        bar.canvas:delete()
        bars[id] = nil
    end
end

return M
