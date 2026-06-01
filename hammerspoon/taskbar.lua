-- 画面下に貼り付くWin風タスクバー
-- ディスプレイごとに「そのディスプレイ上のウィンドウ一覧」を表示し、
-- 左クリックでアクティブ化、右側の×でクローズする。
--
-- 設計メモ:
--   * hs.canvas をディスプレイごとに1枚ずつ作る
--   * hs.window.filter のサブスクリプションで再描画
--   * 全イベントは scheduleRefresh で 200ms にまとめて主スレッド負荷を抑える
--     (連射継続時も最長1秒で必ずflushするmax-wait付きdebounce)
--   * 8秒間隔のフォールバック refresh は filter が取りこぼす Adobe/Parallels 対策

local M = {}

local BAR_H        = 38
local ITEM_W       = 210
local ITEM_GAP     = 4
local ITEM_PAD     = 6
local CLOSE_W      = 21
local ICON_W       = 21
local FONT_SIZE    = 13
local FONT_NAME    = ".AppleSystemUIFont"
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
local refreshDebounce
local lastScreenSig = ""
local refresh -- forward declaration

-- バースト発火するイベントを 200ms trailing debounce で1回に集約
-- (Tahoe の Liquid Glass が windowTitleChanged を連射する対策)
-- タイトル変化の体感反映 200ms 以内なら誤差。AX列挙コストを抑える。
--
-- ただし純 trailing だと 200ms 未満間隔でイベントが来続ける限り
-- コールバックが一度も走らない starvation に陥る (Liquid Glass のタイトル
-- 連射が継続するケース)。MAX_WAIT の締切を設け、バースト開始から最長
-- MAX_WAIT 秒で必ず1回 flush する (leading でなく max-wait 付き trailing)。
local DEBOUNCE_DELAY = 0.2
local MAX_WAIT       = 1.0
local refreshDeadline
local function scheduleRefresh()
    local now = hs.timer.secondsSinceEpoch()
    if refreshDebounce then
        refreshDebounce:stop()
    else
        -- 新しいバーストの開始: 最大待ち時間の締切を設定
        refreshDeadline = now + MAX_WAIT
    end
    -- trailing は now+DEBOUNCE_DELAY だが、締切を超えない範囲に丸める
    local delay = math.min(DEBOUNCE_DELAY, math.max(0, refreshDeadline - now))
    refreshDebounce = hs.timer.doAfter(delay, function()
        refreshDebounce = nil
        refreshDeadline = nil
        refresh()
    end)
end

-- filter 取りこぼし対策のフォールバックポーリング (8秒間隔)
-- ディスプレイスリープ中は止める (寝てる画面に描画して AppKit エラーを吐くため)
local function startPoll()
    if refreshTimer then return end
    refreshTimer = hs.timer.doEvery(8, scheduleRefresh)
end
local function stopPoll()
    if refreshTimer then refreshTimer:stop(); refreshTimer = nil end
end

-- 現在のスクリーンID集合を表す文字列 (構成変化検出用)
local function currentScreenSig()
    local ids = {}
    for _, s in ipairs(hs.screen.allScreens()) do ids[#ids + 1] = s:id() end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- bundleID -> hs.image。成功時のみキャッシュする。
-- 取得失敗(アプリ起動直後でアイコン未準備のとき等)はキャッシュせず、
-- 次回 render で再試行する。失敗を永続キャッシュするとアイコンが
-- 二度と出なくなるため。signature にアイコン有無を含めることで、
-- 後からアイコンが取得できた時点で再描画される (renderBar 参照)。
local iconCache = {}
local function getAppIcon(bid)
    if not bid or bid == "" then return nil end
    local cached = iconCache[bid]
    if cached then return cached end
    local img = hs.image.imageFromAppBundle(bid)
    if img then iconCache[bid] = img end
    return img
end

local function screenIdOf(screen)
    return screen:id()
end

-- ウィンドウがタスクバーに出すべきものか
-- 最小化中もタスクバーに残す (クリックで復元するWin風挙動のため)
-- Hammerspoon自身(canvas)は除外
local function isTaskable(win)
    if not win then return false end
    local app = win:application()
    if not app then return false end
    if app:bundleID() == "org.hammerspoon.Hammerspoon" then return false end
    if win:isStandard() then return true end
    -- Finder は app:hide() 中に win:isStandard() が false に変わるため特例で許可。
    -- 無題ウィンドウ (デスクトップ用) は除外したいので title 必須。
    if app:bundleID() == "com.apple.finder" and app:isHidden() then
        local t = win:title()
        if t and t ~= "" then return true end
    end
    return false
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
            -- Finder の app:hide() もグレーアウト扱い (個別 minimize は出来ないため)
            isMin = win:isMinimized() or (app and app:isHidden()) or false,
            isActive = (win:id() == focusedId),
            app = app,
            -- 取得失敗 (起動直後) は nil。後から取得できたら signature が変わり再描画される
            icon = app and getAppIcon(app:bundleID()) or nil,
        }
        x0 = x0 + ITEM_W + ITEM_GAP
    end

    -- signature: barサイズ + 各item状態。前回と同じなら描画スキップ
    -- アイコン有無も含める (起動直後 nil→取得成功 への遷移で再描画させる)
    local sigParts = { bar.w }
    for _, v in ipairs(visible) do
        sigParts[#sigParts + 1] = v.id .. ":" .. v.title .. ":" ..
            (v.isMin and "m" or "_") .. (v.isActive and "a" or "_") ..
            (v.icon and "i" or "_")
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
        local win, isActive, isMin, title = v.win, v.isActive, v.isMin, v.title

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

        -- アイコン (visible 確定時に取得済み。signature と整合させ二重取得を避ける)
        if v.icon then
            canvas[#canvas + 1] = {
                type = "image",
                image = v.icon,
                frame = { x = x + 4, y = (BAR_H - ICON_W) / 2, w = ICON_W, h = ICON_W },
            }
        end

        -- タイトル
        canvas[#canvas + 1] = {
            type = "text",
            text = title,
            textColor = isMin and TEXT_MIN or TEXT_COLOR,
            textFont = FONT_NAME,
            textSize = FONT_SIZE,
            textLineBreak = "truncateTail",
            frame = {
                x = x + 4 + ICON_W + 4,
                y = math.floor((BAR_H - FONT_SIZE) / 2 - 2),
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
            textFont = FONT_NAME,
            textSize = FONT_SIZE + 4,
            textAlignment = "center",
            frame = { x = closeX, y = math.floor((BAR_H - FONT_SIZE - 4) / 2 - 2), w = CLOSE_W, h = FONT_SIZE + 8 },
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
refresh = function()
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
                -- ターゲットアプリ終了直後の AX 例外などで callback 全体が死ぬのを防ぐ
                local ok, err = pcall(function()
                    local b = bars[id]
                    if not b then return end
                    for _, item in ipairs(b.items) do
                        if x >= item.cx1 and x <= item.cx2 then
                            if item.win then item.win:close() end
                            return
                        elseif x >= item.x1 and x <= item.x2 then
                            local win = item.win
                            if not win then return end
                            local app = win:application()
                            local isHidden = app and app:isHidden()
                            if win:isMinimized() or isHidden then
                                -- 最小化 or hide 中: 復元 + フォーカス
                                if isHidden then app:unhide() end
                                if win:isMinimized() then win:unminimize() end
                                win:focus()
                                win:raise()
                            else
                                local focused = hs.window.focusedWindow()
                                if focused and focused:id() == win:id() then
                                    -- アクティブ中: Finder は hide、他は minimize
                                    if app and app:bundleID() == "com.apple.finder" then
                                        app:hide()
                                    else
                                        win:minimize()
                                    end
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
                if not ok then hs.printf("[taskbar] click failed: %s", err) end
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

    -- 起動時点のスクリーン構成を覚えておく (screen.watcher の誤発火フィルタ用)
    lastScreenSig = currentScreenSig()

    windowFilter = hs.window.filter.new(nil)
    -- すべてのイベントは scheduleRefresh 経由で 200ms にまとめる
    -- windowMoved は購読しない (タスクバーは位置を表示しないので不要)。
    -- ディスプレイ間移動は 8秒 poll または以後の focus/title イベントで拾える。
    windowFilter:subscribe({
        hs.window.filter.windowCreated,
        hs.window.filter.windowDestroyed,
        hs.window.filter.windowFocused,
        hs.window.filter.windowUnfocused,
        hs.window.filter.windowMinimized,
        hs.window.filter.windowUnminimized,
        hs.window.filter.windowTitleChanged,
    }, scheduleRefresh)

    -- filter が取りこぼす環境(Adobe / Parallels)向けの保険ポーリング
    startPoll()

    -- ディスプレイ構成変更で全部作り直し
    -- Tahoe は Stage Manager/sleep復帰/カラープロファイル変更で誤発火しやすいので
    -- スクリーンID集合に変化があったときだけ canvas を再生成する
    M._screenWatcher = hs.screen.watcher.new(function()
        local sig = currentScreenSig()
        if sig ~= lastScreenSig then
            lastScreenSig = sig
            for id, bar in pairs(bars) do
                bar.canvas:delete()
                bars[id] = nil
            end
        end
        scheduleRefresh()
    end):start()

    -- app:hide() / unhide は windowFilter の通常イベントで拾えないので
    -- application.watcher で hidden/unhidden を捉えて再描画
    M._appWatcher = hs.application.watcher.new(function(_, eventType, _)
        if eventType == hs.application.watcher.hidden
            or eventType == hs.application.watcher.unhidden then
            scheduleRefresh()
        end
    end):start()

    -- ディスプレイスリープ中はポーリングを止める (寝てる画面への描画でAppKitエラー)
    M._caffeinateWatcher = hs.caffeinate.watcher.new(function(eventType)
        if eventType == hs.caffeinate.watcher.screensDidSleep then
            stopPoll()
        elseif eventType == hs.caffeinate.watcher.screensDidWake then
            startPoll()
            scheduleRefresh()
        end
    end):start()

    refresh()
end

function M.stop()
    stopPoll()
    if refreshDebounce then refreshDebounce:stop(); refreshDebounce = nil end
    if windowFilter then windowFilter:unsubscribeAll(); windowFilter = nil end
    if M._screenWatcher then M._screenWatcher:stop(); M._screenWatcher = nil end
    if M._appWatcher then M._appWatcher:stop(); M._appWatcher = nil end
    if M._caffeinateWatcher then M._caffeinateWatcher:stop(); M._caffeinateWatcher = nil end
    for id, bar in pairs(bars) do
        bar.canvas:delete()
        bars[id] = nil
    end
end

return M
