-- ウィンドウ操作の Hammerspoon 自前アニメーションを無効化（即時反映）
hs.window.animationDuration = 0

-- AX (アクセシビリティAPI) の応答待ち上限。既定はシステム値 (約6秒) で、
-- Parallels コヒーレンスや Adobe のように AX サーバが詰まるアプリが1つでもいると
-- その1回の問い合わせがメインスレッドを数秒ブロックする。
-- HS の Lua はメインスレッド1本なので、その間 eventtap のコールバックも返せず、
-- macOS がタップを「タイムアウトした」と見なして無効化する
-- (= Chrome の中クリック⇔右クリック入替が無言で死ぬ)。
-- 1秒で切ることで、詰まったアプリの窓が一時的にタスクバーから消えるだけで済ませる。
-- ※これは「1回のAX呼び出し」の上限。refresh 全体 (ウィンドウ数×6〜7回) の合計を
--   縛るものではないので、下の watchdog と併用して初めて意味を持つ。
-- 失敗しても false を返すだけで例外にならないため、黙って既定値のままにならないよう記録する。
if not hs.window.timeout(1) then
    hs.printf("[init] hs.window.timeout(1) failed; AX timeout stays at the system default (~6s)")
end

-- hammerspoon://reload で設定再読込を可能にする
hs.urlevent.bind("reload", function() hs.reload() end)

-- 画面下に貼り付くWin風タスクバー (ディスプレイ別)
local taskbar = require("taskbar")
taskbar.start()

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

-- x座標で左から右にソートした N番目 (0始まり) のディスプレイを返す。
-- idx がディスプレイ数を超える場合は最右にクランプする。これは意図的で、
-- F13+2 (="右", idx=2/3画面想定) を常に最右に着地させるため。
-- ただしディスプレイ2枚以下では "中央" (idx=1) も最右に丸められる点に注意。
local function screenAtIndex(idx)
    local screens = hs.screen.allScreens()
    if #screens == 0 then return nil end
    table.sort(screens, function(a, b)
        return a:fullFrame().x < b:fullFrame().x
    end)
    idx = math.max(0, math.min(idx, #screens - 1))
    return screens[idx + 1]
end

-- hammerspoon://moveToDisplay?idx=N[&dockw=N][&taskbar=N]
-- fullFrame() ベースで決定論的に計算する。
-- frame() (visibleFrame) は Dock の位置・auto-hide 状態で返り値が変わるため使わない。
-- メニューバー高さは fullFrame と frame の差から検出 (Dock の有無に関係なく安定)。
-- dockw=N は右端から差し引くピクセル数 (右配置の Mac Dock 回避用)。
-- taskbar=N は下端から差し引くピクセル数 (下配置の Mac Dock や Windows タスクバー回避用)。
-- 省略時は自作タスクバーの実高さ (taskbar.BAR_H) を使う。呼び出し側 (Karabiner の
-- URL) に高さを書かないことで値の二重管理を避ける。回避したくない場合は taskbar=0。
-- taskbar>0 のときは自作タスクバーのカーソルガード帯(透明帯 4px)に下端が埋もれて
-- アプリ自身のリサイズカーソル(↕)が出たり消えたりするため、さらに余白を空けて縮める。
local TASKBAR_GAP = 8
hs.urlevent.bind("movetodisplay", function(_, params)
    local idx = tonumber(params.idx) or 0
    local dockw = tonumber(params.dockw) or 0
    -- モジュール taskbar を隠さないよう別名にする (以前 local taskbar で覆っていた)
    local taskbarH = tonumber(params.taskbar) or taskbar.BAR_H
    local gap = (taskbarH > 0) and TASKBAR_GAP or 0

    local screen = screenAtIndex(idx)
    if not screen then return end

    local full = screen:fullFrame()
    local vis = screen:frame()
    local menubarH = vis.y - full.y  -- メニューバーがこの画面にある場合 >0

    local x = full.x
    local y = full.y + menubarH
    local w = full.w - dockw
    local h = full.h - menubarH - taskbarH - gap

    local target, kind = focusedTarget()
    if not target then return end
    -- 無駄打ち防止: 既に目的地と数px以内なら setFrame しない。
    -- F13+同一ディスプレイの連打で Parallels コヒーレンス窓へ移動要求が無駄に
    -- 積み上がり WindowServer を固めた件 (2026-06-29) の軽量ガード。
    if kind == "window" then
        local c = target:frame()
        if c and math.abs(c.x - x) < 4 and math.abs(c.y - y) < 4
             and math.abs(c.w - w) < 4 and math.abs(c.h - h) < 4 then
            return
        end
    end
    setTargetFrame(target, kind, x, y, w, h)
end)

-- hammerspoon://prevwindow
-- 直前まで手前にあったウィンドウへフォーカスを移す (Win風 Alt+Tab の交互トグル)。
-- 状態は一切持たず、毎回ウィンドウサーバの重なり順 (orderedWindows) を読むだけ。
-- [1] は現在の手前窓なので、それ以外の最初の通常ウィンドウ = 直前の窓。
-- フォーカスは「読む」のではなく「セットする」だけなので Parallels の固着の影響を受けにくく、
-- 毎回作り直すため状態のズレも起きない。
hs.urlevent.bind("prevwindow", function(_, _)
    local cur = hs.window.focusedWindow()
    for _, w in ipairs(hs.window.orderedWindows()) do
        if w ~= cur and w:isStandard()
            and w:application() and w:application():bundleID() ~= "org.hammerspoon.Hammerspoon" then
            w:focus()
            return
        end
    end
end)

-- hammerspoon://minimizedisplay
-- アクティブウィンドウ 1 つだけを minimize する。
-- 注: 現状この URL は karabiner のどのキーにも割り当てていない (F13+F は「更新」に変更済み)。
--     手動 URL 起動や将来の再バインド用に残してある。
-- Finder は win:minimize() で AX 列挙から落ちる仕様のため app:hide() に分岐
-- (app:hide() は全 Finder 窓に効くが taskbar 側で app:isHidden() を拾い続けるので消えない)。
hs.urlevent.bind("minimizedisplay", function(_, _)
    local focused = hs.window.focusedWindow()
    if not focused then return end
    local app = focused:application()
    if app and app:bundleID() == "com.apple.finder" then
        app:hide()
    else
        focused:minimize()
    end
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
-- コールバックは pcall で保護する。getProperty 等で例外が出てもタップを
-- 巻き込んで殺さないようにし、恒久的な機能停止を防ぐ。
--
-- 前提: トラックパッドの中クリックは MiddleClick.app が供給している。
-- MiddleClick の "Tap to click" は必ず OFF (= 3本指の物理押し込みを要求) にする。
-- ONだと3本指タップで中クリックが合成され、文字入力中に手のひらが3点触れただけで
-- ここが右クリックに変換し、Chrome にコンテキストメニューが暴発する。
-- macOS 側の「タップでクリック」設定とは無関係に発火するのでOSでは止められない。
--
-- 変換の可否は「押した瞬間」に判定して離すまで保持する (down/up を必ず対で扱う)。
-- up のたびに前面アプリを見直すと、押している最中に Chrome が前面から外れた場合に
-- down だけ変換され up が素通りし、Chrome にボタン押下状態が残ってしまうため。
local middleSwapped = false   -- 中ボタン→右 に変換中
local rightSwapped  = false   -- 右→中ボタン に変換中

local function chromeIsFrontmost()
    local app = hs.application.frontmostApplication()
    return app ~= nil and app:bundleID() == "com.google.Chrome"
end

mouseSwapWatcher = hs.eventtap.new({
    hs.eventtap.event.types.otherMouseDown,
    hs.eventtap.event.types.otherMouseUp,
    hs.eventtap.event.types.rightMouseDown,
    hs.eventtap.event.types.rightMouseUp,
}, function(event)
    local ok, handled, replacement = pcall(function()
        local types = hs.eventtap.event.types
        local props = hs.eventtap.event.properties
        local eventType = event:getType()

        if eventType == types.otherMouseDown then
            if event:getProperty(props.mouseEventButtonNumber) ~= 2 then return false end
            middleSwapped = chromeIsFrontmost()
            if not middleSwapped then return false end
            return true, { hs.eventtap.event.newMouseEvent(types.rightMouseDown, event:location()) }

        elseif eventType == types.otherMouseUp then
            if event:getProperty(props.mouseEventButtonNumber) ~= 2 then return false end
            if not middleSwapped then return false end
            middleSwapped = false
            return true, { hs.eventtap.event.newMouseEvent(types.rightMouseUp, event:location()) }

        elseif eventType == types.rightMouseDown then
            rightSwapped = chromeIsFrontmost()
            if not rightSwapped then return false end
            local e = hs.eventtap.event.newMouseEvent(types.otherMouseDown, event:location())
            e:setProperty(props.mouseEventButtonNumber, 2)
            return true, { e }

        elseif eventType == types.rightMouseUp then
            if not rightSwapped then return false end
            rightSwapped = false
            local e = hs.eventtap.event.newMouseEvent(types.otherMouseUp, event:location())
            e:setProperty(props.mouseEventButtonNumber, 2)
            return true, { e }
        end

        return false
    end)

    if not ok then
        hs.printf("[mouseSwap] callback failed: %s", tostring(handled))
        return false
    end
    if handled then return true, replacement end
    return false
end):start()

-- macOS はコールバックが重い/タイムアウトするとタップを自動無効化する。
-- 定期的に生存確認し、無効化されていたら再有効化して機能を自動復旧する。
-- isEnabled() は CGEventTapIsEnabled を見ているので OS 側の無効化を検出できる。
-- Hammerspoon 自身はコールバック内で自動再有効化していないため、この watchdog が
-- 唯一の復旧経路であり、間隔がそのまま「無言でクリック変換が死んでいる最大時間」に
-- なる。5秒では体感で気づいてしまうので1秒にする (CGEventTapIsEnabled は安価)。
local WATCHDOG_INTERVAL = 1
mouseSwapWatchdog = hs.timer.doEvery(WATCHDOG_INTERVAL, function()
    if mouseSwapWatcher and not mouseSwapWatcher:isEnabled() then
        hs.printf("[mouseSwap] tap was disabled by the OS; re-enabling")
        mouseSwapWatcher:start()
    end
end)

-- hammerspoon://reload (= hs.reload) や終了の前に OS リソースを握る
-- eventtap / timer / watcher を明示停止する。Lua ステートは作り直されるが
-- 旧インスタンスの GC が遅れると二重登録 (クリック二重変換・描画多重) を
-- 招くため、shutdownCallback で確実に畳む。
hs.shutdownCallback = function()
    if mouseSwapWatchdog then mouseSwapWatchdog:stop(); mouseSwapWatchdog = nil end
    if mouseSwapWatcher then mouseSwapWatcher:stop(); mouseSwapWatcher = nil end
    taskbar.stop()
end
