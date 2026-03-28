-- 「local」を消してグローバル変数にすることで、掃除されるのを防ぎます
eisuTapWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    local keyCode = event:getKeyCode()

    -- 102番は「英数」キー
    if keyCode == 102 then
        local now = hs.timer.secondsSinceEpoch()

        -- 0.3秒以内に再度押された場合
        if now - (lastEisuPress or 0) < 0.3 then
            hs.eventtap.keyStroke({}, 104) -- かなキーを送信
            hs.alert.show("JAPANESE")
            lastEisuPress = 0
        else
            lastEisuPress = now
        end
    end

    return false
end):start()

-- F13専用の「モード」を作成
local f13Mode = hs.hotkey.modal.new()

-- F13を「押し下げた時」にモード開始、「離した時」に終了
hs.hotkey.bind({}, "f13", function()
    f13Mode:enter()
end, function()
    f13Mode:exit()
end)

-- F13モード中だけHJKLを矢印キーにする
local keys = {
    h = "left",
    j = "down",
    k = "up",
    l = "right"
}

for key, direction in pairs(keys) do
    f13Mode:bind({}, key, function()
        hs.eventtap.keyStroke({}, direction)
    end)
end

-- Chrome: マウスセンターボタン⇔右クリック入れ替え
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