-- ウィンドウ操作の Hammerspoon 自前アニメーションを無効化（即時反映）
hs.window.animationDuration = 0

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
mouseSwapWatcher = hs.eventtap.new({
    hs.eventtap.event.types.otherMouseDown,
    hs.eventtap.event.types.otherMouseUp,
    hs.eventtap.event.types.rightMouseDown,
    hs.eventtap.event.types.rightMouseUp,
}, function(event)
    local ok, handled, replacement = pcall(function()
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
mouseSwapWatchdog = hs.timer.doEvery(5, function()
    if mouseSwapWatcher and not mouseSwapWatcher:isEnabled() then
        mouseSwapWatcher:start()
    end
end)

-- 英数(japanese_eisuu) ダブルタップ → かな (Parallels前面時は Ctrl+Cmd+5 = Win IME ON)
-- AHK と同様に「押下時刻」で判定するため、間に別キーが入っても時間内なら発火する。
-- (Karabiner の to_delayed_action は介在キーでキャンセルされ、この挙動を素直に作れない)
-- イベントは一切消費しない。2打目の 英数/Ctrl+Cmd+4 はそのまま流し、その直後に
-- かな/Ctrl+Cmd+5 を追送する (= 英数→かな の順で確定。順序保証のため次サイクルで post)。
-- 信号キー: Mac標準IME時は Karabiner が japanese_eisuu(102) を出力、Parallels時は
-- Ctrl+Cmd+4(keycode 21 + ctrl+cmd) を出力するため、前面アプリで分岐する。
local EISU_KEYCODE        = 102   -- kVK_JIS_Eisu
local KANA_KEYCODE        = 104   -- kVK_JIS_Kana
local KEY4_KEYCODE        = 21    -- kVK_ANSI_4 (Parallels時の Ctrl+Cmd+4)
-- Mac側のかな確定先 (Google日本語入力)。TISで直接切替するための入力ソースID。
-- 取得元: かな入力中に Hammerspoon Console で hs.keycodes.currentSourceID() を実行した値。
-- IME を変えたら要更新 (例: ことえりなら com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese)。
local MAC_KANA_SOURCE_ID  = "com.google.inputmethod.Japanese.base"
-- 0.5秒。純粋な連打だけなら0.3で足りるが、間に1打(Backspace等)挟むと
-- その分の時間が乗るため、介在キーを許容できるよう少し広げてある。
-- 広げすぎると「英数→素早く数文字→英数」が誤ってかな化するので要バランス。
local EISU_DOUBLE_TAP_SEC = 0.5
local eisuLastTapAt = nil

-- IME切替キーは「別プロセス System Events」に送らせる。
-- 理由: Hammerspoon プロセス自身の合成キー送出 (CGEventPost / :post() / keyStroke) は、
-- Parallels の winapp.* 大量 churn や RDP 多用の下で静かに毒され、無音で効かなくなる
-- (eventtap も timer も検出も生きているのに :post() だけ no-op 化。HS を作り直すまで
-- 復活しない)。これはシステム全体や Secure Input の問題ではなく HS プロセス固有で、
-- 別プロセスからの送出は健全なことを実機で確認済み。よって実際の post は System Events
-- (別プロセス) に肩代わりさせ、毒を確実に迂回する。
-- 送り方は hs.osascript で HS 内から Apple Event を投げる方式。osascript バイナリを
-- 毎回起動する版 (~25ms) と違い、プロセス起動コストが無く Apple Event 往復で済む。
-- 同期実行で runloop を数ms塞ぐが、呼び出しは doAfter 経由でダブルタップ時のみ。
-- System Events がコールドだと初回が重いので下の prewarm で常駐させておく。
local function sendImeKey(applescript)
    hs.osascript.applescript(applescript)
end

-- System Events を起動時に常駐させ quit delay 0 で自動終了を抑止する
-- (sendImeKey をコールド起動遅延なしの Apple Event 往復だけにするため)。
-- prewarm 自体は起動を塞がないよう非同期 (hs.task) で投げる。
hs.task.new("/usr/bin/osascript", nil,
    { "-e", 'tell application "System Events" to set quit delay to 0' }):start()

-- Parallels が前面かを「キー押下のたびにライブで」判定する。
-- 注: 以前 activated イベント駆動のキャッシュにしたが、フルスクリーン/Spaces 切替では
-- activated が飛ばずキャッシュが stale になり、Karabiner 側の分岐 (Parallels時=Ctrl+Cmd+4 /
-- Mac時=英数102) と食い違って検出ゼロになった。両者を確実に同期させるためライブ判定に戻す。
-- (間欠故障の真因は前面判定ではなく合成キー送出の毒だったので、キャッシュ化は不要だった)
local function isParallelsFrontmost()
    local app = hs.application.frontmostApplication()
    local b = app and app:bundleID()
    if not b then return false end
    return b == "com.parallels.desktop.console" or b:find("^com%.parallels%.winapp%.") ~= nil
end

eisuDoubleTapWatcher = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
    local ok, err = pcall(function()
        -- オートリピート(押しっぱなし)は連打と誤検出しないよう無視
        if event:getProperty(hs.eventtap.event.properties.keyboardEventAutorepeat) ~= 0 then return end

        local parallels = isParallelsFrontmost()
        local kc = event:getKeyCode()
        local isSignal
        if parallels then
            local f = event:getFlags()
            isSignal = (kc == KEY4_KEYCODE and f.ctrl and f.cmd)
        else
            isSignal = (kc == EISU_KEYCODE)
        end
        if not isSignal then return end

        local now = hs.timer.secondsSinceEpoch()
        if eisuLastTapAt and (now - eisuLastTapAt) < EISU_DOUBLE_TAP_SEC then
            eisuLastTapAt = nil  -- 連続発火を防ぐ (3打目はまた1打目扱い)
            hs.printf("[eisuDoubleTap] fire parallels=%s", tostring(parallels))
            -- 別プロセス経由で送出 (sendImeKey の理由は上のコメント参照)。
            -- Parallels: Ctrl+Cmd+5 (Win IME ON) / Mac: かな(keycode 104)。
            -- 2打目 (Parallels時は Karabiner が出す Ctrl+Cmd+4=IME OFF) を完全に流し切って
            -- から追送しないと、ゲスト IME に OFF→ON が競合して入り一瞬入力が固まる。
            -- 次イベントループへ遅延 (doAfter 0) して順序を保証する。
            hs.timer.doAfter(0, function()
                if parallels then
                    -- ゲストには Ctrl+Cmd+5 を送るしかない。System Events 経由 (snag は許容)。
                    sendImeKey('tell application "System Events" to key code 23 using {control down, command down}')
                else
                    -- Mac側はキーを送らず TIS で入力ソースを直接かなへ切替。
                    -- TIS は CGEventSource を使わない別経路なので合成キー送出の単一ソース死
                    -- (sendImeKey のコメント参照) と無縁で即時、snag も出ない。
                    -- 万一切替に失敗したら従来のキー送出にフォールバック。
                    if not hs.keycodes.currentSourceID(MAC_KANA_SOURCE_ID) then
                        sendImeKey('tell application "System Events" to key code ' .. KANA_KEYCODE)
                    end
                end
            end)
        else
            eisuLastTapAt = now
        end
    end)
    if not ok then hs.printf("[eisuDoubleTap] callback failed: %s", tostring(err)) end
    return false  -- 常に素通し (イベントを消費しない)
end):start()

eisuDoubleTapWatchdog = hs.timer.doEvery(5, function()
    if eisuDoubleTapWatcher and not eisuDoubleTapWatcher:isEnabled() then
        eisuDoubleTapWatcher:start()
    end
end)

-- hammerspoon://reload (= hs.reload) や終了の前に OS リソースを握る
-- eventtap / timer / watcher を明示停止する。Lua ステートは作り直されるが
-- 旧インスタンスの GC が遅れると二重登録 (クリック二重変換・描画多重) を
-- 招くため、shutdownCallback で確実に畳む。
hs.shutdownCallback = function()
    if mouseSwapWatchdog then mouseSwapWatchdog:stop(); mouseSwapWatchdog = nil end
    if mouseSwapWatcher then mouseSwapWatcher:stop(); mouseSwapWatcher = nil end
    if eisuDoubleTapWatchdog then eisuDoubleTapWatchdog:stop(); eisuDoubleTapWatchdog = nil end
    if eisuDoubleTapWatcher then eisuDoubleTapWatcher:stop(); eisuDoubleTapWatcher = nil end
    taskbar.stop()
end
