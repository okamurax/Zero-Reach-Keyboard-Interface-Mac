-- ウィンドウ操作の Hammerspoon 自前アニメーションを無効化（即時反映）
hs.window.animationDuration = 0

-- 画面下に貼り付くWin風タスクバー (ディスプレイ別)
require("taskbar").start()

-- 前面ウィンドウを取得。標準の AXWindow が無い場合 (Adobe Bridge等) は
-- トップレベルの AXLayoutArea にフォールバック
local function focusedTarget()
    local win = hs.window.focusedWindow()
    if win then return win, "window" end

    local app = hs.application.frontmostApplication()
    if not app then return nil end
    local axApp = hs.axuielement.applicationElement(app)
    if not axApp then return nil end
    for _, child in ipairs(axApp:attributeValue("AXChildren") or {}) do
        if child:attributeValue("AXRole") == "AXLayoutArea" then
            return child, "axlayoutarea"
        end
    end
    return nil
end

local function setTargetFrame(target, kind, x, y, w, h)
    if kind == "window" then
        target:setFrame({ x = x, y = y, w = w, h = h }, 0)
    else
        target:setAttributeValue("AXPosition", { x = x, y = y })
        target:setAttributeValue("AXSize", { w = w, h = h })
    end
end

local function setTargetSize(target, kind, w, h)
    if kind == "window" then
        target:setSize({ w = w, h = h })
    else
        target:setAttributeValue("AXSize", { w = w, h = h })
    end
end

-- x座標で左から右にソートしたディスプレイを返す
local function screenAtIndex(idx)
    local screens = hs.screen.allScreens()
    table.sort(screens, function(a, b)
        return a:fullFrame().x < b:fullFrame().x
    end)
    if idx >= #screens then idx = #screens - 1 end
    if idx < 0 then idx = 0 end
    return screens[idx + 1]
end

-- hammerspoon://moveToDisplay?idx=N[&dockw=N][&taskbar=N]
-- fullFrame() ベースで決定論的に計算する。
-- frame() (visibleFrame) は Dock の位置・auto-hide 状態で返り値が変わるため使わない。
-- メニューバー高さは fullFrame と frame の差から検出 (Dock の有無に関係なく安定)。
-- dockw=N は右端から差し引くピクセル数 (右配置の Mac Dock 回避用)。
-- taskbar=N は下端から差し引くピクセル数 (下配置の Mac Dock や Windows タスクバー回避用)。
hs.urlevent.bind("movetodisplay", function(_, params)
    local idx = tonumber(params.idx) or 0
    local dockw = tonumber(params.dockw) or 0
    local taskbar = tonumber(params.taskbar) or 0

    local screen = screenAtIndex(idx)
    if not screen then return end

    local full = screen:fullFrame()
    local vis = screen:frame()
    local menubarH = vis.y - full.y  -- メニューバーがこの画面にある場合 >0

    local x = full.x
    local y = full.y + menubarH
    local w = full.w - dockw
    local h = full.h - menubarH - taskbar

    local target, kind = focusedTarget()
    if not target then return end
    setTargetFrame(target, kind, x, y, w, h)
end)

-- hammerspoon://minimizedisplay
-- フォーカス中のウィンドウが乗っているディスプレイ上の全ウィンドウを minimize する。
-- Parallels Coherence ウィンドウでも自作タスクバーから消えずグレーアウトで残る経路。
-- Windows native の最小化 (AHK WinMinimize / タイトルバー / Win+Down) は Parallels 経由で
-- macOS 側ウィンドウを「非表示」状態にしてしまい hs.window.allWindows() から脱落するため使えない。
hs.urlevent.bind("minimizedisplay", function(_, _)
    local focused = hs.window.focusedWindow()
    if not focused then return end
    local targetScreen = focused:screen()
    if not targetScreen then return end

    local screenId = targetScreen:id()
    for _, win in ipairs(hs.window.allWindows()) do
        local s = win:screen()
        if s and s:id() == screenId and not win:isMinimized() then
            win:minimize()
        end
    end
end)

-- hammerspoon://triggerclaunch
-- 直近に使った Parallels 関連ウィンドウ (VMコンソール / Coherence Windowsアプリ) にフォーカスを
-- 移してから Ctrl+Shift+F12 を送出 → Windows 側グローバルホットキーで CLaunch を呼ぶ。
-- CLaunch は VM 内で常駐 (Windowsスタートアップ登録) されている前提。
-- Mac側のどのアプリにフォーカスがあっても VM 内に届くので「どこからでも CLaunch」が成立する。
hs.urlevent.bind("triggerclaunch", function(_, _)
    -- 優先順位: (1) Coherence Windows アプリ (com.parallels.winapp.*)
    --          (2) Parallels Desktop 本体 (com.parallels.desktop.console)
    -- Coherence では各 Windows アプリが別プロセス。本体ではなく winapp.* を activate しないと
    -- VM 内に入力フォーカスが届かないため、可視ウィンドウを持つ winapp を優先する。
    local coherence, console = nil, nil
    for _, app in ipairs(hs.application.runningApplications()) do
        local bid = app:bundleID() or ""
        if bid:match("^com%.parallels%.winapp%.") then
            local wins = app:visibleWindows()
            if wins and #wins > 0 then
                coherence = app
                break
            elseif not coherence then
                coherence = app
            end
        elseif bid == "com.parallels.desktop.console" then
            console = app
        end
    end

    local target = coherence or console
    if not target then return end
    target:activate()
    hs.timer.doAfter(0.25, function()
        hs.eventtap.keyStroke({"ctrl", "shift"}, "f12", 0)
    end)
end)

-- hammerspoon://resizeModerate
-- 1200x750 固定サイズ。位置は変えない
-- リサイズ後にタイトルバー中央へカーソルを移動して、そのままドラッグで動かせるようにする
hs.urlevent.bind("resizemoderate", function(_, _)
    local winW = 1200
    local winH = 750

    local target, kind = focusedTarget()
    if not target then return end
    setTargetSize(target, kind, winW, winH)

    local pos
    if kind == "window" then
        local frame = target:frame()
        pos = { x = frame.x + winW / 2, y = frame.y + 12 }
    else
        local p = target:attributeValue("AXPosition")
        if p then pos = { x = p.x + winW / 2, y = p.y + 12 } end
    end
    if pos then hs.mouse.absolutePosition(pos) end
end)

-- Chrome: マウスセンターボタン⇔右クリック入れ替え
-- （トラックパッド対応のため Karabiner ではなく Hammerspoon で処理）
mouseSwapWatcher = hs.eventtap.new({
    hs.eventtap.event.types.otherMouseDown,
    hs.eventtap.event.types.otherMouseUp,
    hs.eventtap.event.types.rightMouseDown,
    hs.eventtap.event.types.rightMouseUp,
}, function(event)
    local app = hs.application.frontmostApplication()
    if not app or app:bundleID() ~= "com.google.Chrome" then
        return false
    end

    local eventType = event:getType()

    if eventType == hs.eventtap.event.types.otherMouseDown and event:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber) == 2 then
        return true, { hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseDown, event:location()) }
    elseif eventType == hs.eventtap.event.types.otherMouseUp and event:getProperty(hs.eventtap.event.properties.mouseEventButtonNumber) == 2 then
        return true, { hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.rightMouseUp, event:location()) }
    elseif eventType == hs.eventtap.event.types.rightMouseDown then
        local e = hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.otherMouseDown, event:location())
        e:setProperty(hs.eventtap.event.properties.mouseEventButtonNumber, 2)
        return true, { e }
    elseif eventType == hs.eventtap.event.types.rightMouseUp then
        local e = hs.eventtap.event.newMouseEvent(hs.eventtap.event.types.otherMouseUp, event:location())
        e:setProperty(hs.eventtap.event.properties.mouseEventButtonNumber, 2)
        return true, { e }
    end

    return false
end):start()
