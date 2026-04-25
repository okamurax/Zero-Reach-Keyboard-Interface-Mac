-- ウィンドウ操作の Hammerspoon 自前アニメーションを無効化（即時反映）
hs.window.animationDuration = 0

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

-- hammerspoon://moveToDisplay?idx=N[&dock=right][&taskbar=N]
-- 旧 assets/scripts/move_to_display.sh の置き換え。osascript 起動コストを回避
hs.urlevent.bind("movetodisplay", function(_, params)
    local idx = tonumber(params.idx) or 0
    local dockRight = params.dock == "right"
    local taskbar = tonumber(params.taskbar) or 0

    local screen = screenAtIndex(idx)
    if not screen then return end

    -- frame() は Dock / メニューバーを除いた領域（NSScreen の visibleFrame に相当）
    local f = screen:frame()
    local x, y, w, h = f.x, f.y, f.w, f.h

    if dockRight then
        local full = screen:fullFrame()
        local dockW = (full.x + full.w) - (f.x + f.w)
        w = w - dockW
    end

    if taskbar > 0 then
        h = h - taskbar
    end

    local target, kind = focusedTarget()
    if not target then return end
    setTargetFrame(target, kind, x, y, w, h)
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
