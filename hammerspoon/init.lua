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

-- 移動先のディスプレイを役割で選ぶ。x 座標の並び順では選ばない
-- (上に1枚足したら、その画面が並びの途中に入り、F13+2 が母艦へ、F13+C が上の画面へずれた)。
--   left   = 左端が一番左の画面
--   right  = 右端が一番右の画面
--   center = 母艦 (メニューバーのある主画面。下段の中央)
--   top    = 上端が一番上の画面 (母艦の上に置いた画面)
local function screenFor(role)
    if role == "center" then return hs.screen.primaryScreen() end
    local best
    for _, s in ipairs(hs.screen.allScreens()) do
        local f = s:fullFrame()
        if not best
            or (role == "left" and f.x < best:fullFrame().x)
            or (role == "right" and f.x + f.w > best:fullFrame().x + best:fullFrame().w)
            or (role == "top" and f.y < best:fullFrame().y) then
            best = s
        end
    end
    return best
end

-- 前面ウィンドウを role (left / right / center / top) のディスプレイへ移動+最大化する。
-- fullFrame() ベースで決定論的に計算する。
-- frame() (visibleFrame) は Dock の位置・auto-hide 状態で返り値が変わるため使わない。
-- メニューバー高さは fullFrame と frame の差から検出 (Dock の有無に関係なく安定)。
-- dockw は右端から差し引くピクセル数 (右配置の Mac Dock 回避用)。
-- 下端は自作タスクバーの実高さ (taskbar.BAR_H) を差し引く。値は taskbar.lua にだけ持つ。
-- さらに余白を空けるのは、自作タスクバーのカーソルガード帯(透明帯 4px)に下端が埋もれて
-- アプリ自身のリサイズカーソル(↕)が出たり消えたりするため。
local TASKBAR_GAP = 8
local function moveToDisplay(role, dockw)
    dockw = dockw or 0

    local screen = screenFor(role)
    if not screen then return end

    local full = screen:fullFrame()
    local vis = screen:frame()
    local menubarH = vis.y - full.y  -- メニューバーがこの画面にある場合 >0

    local x = full.x
    local y = full.y + menubarH
    local w = full.w - dockw
    local h = full.h - menubarH - taskbar.BAR_H - TASKBAR_GAP

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
end

-- 1200x750 固定サイズ。位置は変えない
-- リサイズ後にタイトルバー中央へカーソルを移動して、そのままドラッグで動かせるようにする
local function resizeModerate()
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
end

-- ~/Downloads の置き場 (自作アプリ DownloadsShelf、downloads-shelf/) を裏で起動しておく。
-- 英数+E (⌃⌥⌘F16) の出し入れと配置はアプリ自身が Carbon ホットキーで行う。ここは常駐させるだけ。
-- 起動中なら何もしない (HS リロードのたびに open しない)。
if not hs.application.get("local.zero-reach.downloads-shelf") then
    hs.task.new("/usr/bin/open", nil, { "-g", "-b", "local.zero-reach.downloads-shelf" }):start()
end

-- F13+¥ (⌃⌥⌘F17): 範囲を選んで撮影し、クリップボードかファイル (~/Downloads) かをその場で選ぶ。
-- 一時ファイルに撮って画像をメモリに読んだら一時ファイルはすぐ消し、マウス位置に2行だけの
-- メニューを出す。選ばずに閉じる (Esc や外をクリック) と何も残らない。連続撮影でクリップボード
-- だけ使う時に ~/Downloads が不要なファイルで埋まらないようにするため
local captureTask  -- 撮影中 (範囲を選ぶ間) に GC されて終了処理が呼ばれなくならないよう保持する
local function captureWithChoice()
    local tmp = string.format("%szr-capture-%d.png", hs.fs.temporaryDirectory(), os.time())
    captureTask = hs.task.new("/usr/sbin/screencapture", function()
        local img = hs.image.imageFromPath(tmp)
        os.remove(tmp)
        if not img then return end
        local menu = hs.menubar.new(false)
        menu:setMenu({
            { title = "クリップボード", fn = function() hs.pasteboard.writeObjects(img) end },
            { title = "ファイル", fn = function()
                img:saveToFile(string.format("%s/Downloads/スクリーンショット %s.png", os.getenv("HOME"), os.date("%Y-%m-%d %H.%M.%S")))
            end },
        })
        menu:popupMenu(hs.mouse.absolutePosition())
        menu:delete()
    end, { "-i", tmp }):start()
end

-- F13+C を 400ms 以内に2回 (⌃⌥⌘F19): ウィンドウを上のディスプレイへ移動+最大化。
-- 2回押しの判定は Karabiner 側 (HS は状態を持たない)。1回目の F19 で母艦へ移った後にここで上へ移す。
-- 直後だと母艦への移動 (狭い幅) が後から効いて、上の画面で幅が足りなくなる。
-- 0.3 秒後にもう一度合わせる (合っていれば moveToDisplay の無駄打ち防止で何もしない)
local function moveToTop()
    moveToDisplay("top")
    hs.timer.doAfter(0.3, function() moveToDisplay("top") end)
end

-- Karabiner からのウィンドウ操作トリガ (F13レイヤー)。
--
-- 以前は Karabiner の shell_command で `open -g 'hammerspoon://...'` を叩いていたが、
-- 1押下ごとに sh の fork + open の fork + LaunchServices への IPC が走っていた。
-- 「同位置なら setFrame しない」ガードは Hammerspoon 側、つまりプロセス起動より後に
-- あるため連打時の生成圧力を一切減らせておらず、VM再起動直後の F13 連打で
-- WindowServer を固めた件の根本原因が残ったままだった。
-- Karabiner に F16〜F20 を直接送らせ、ここで受けることでプロセス生成が丸ごと消える。
--
-- F16〜F20 を選んだ理由: macOS 標準ホットキー (symbolichotkeys) が F13〜F20 のうち
-- F14/F15 のみ使用しており、F16以降は未使用。Parallels は F14系以降をグラブしない
-- (Spotlight を Cmd+F14、AltTab を Cmd+F13 で運用できている実績と同じ理屈)。
-- 修飾キーは付けない。Karabiner の from が optional:any で物理修飾キーを素通しするため、
-- 修飾付きにすると Shift 等を巻き込んだ時にホットキーの完全一致から外れて不発になる。
--
-- F16 は空き (旧 F13+V の直前ウィンドウ。F13+V は Chrome のタブ分割に移した)。
-- F16〜F20 を使い切り、macOS には F21 以降のキーコードが無いため、以降は
-- Ctrl+Opt+Cmd+F16 のように修飾付きで増やす。上記の不発条件はあるが、
-- 英数レイヤーのように物理修飾キーを併用しない操作に限れば実害はない
-- (英数+E の ⌃⌥⌘F16 は DownloadsShelf が自前で受け、F13+¥ の ⌃⌥⌘F17 と F13+C 2回の ⌃⌥⌘F19 は下の表)。
local HYPER = { "ctrl", "alt", "cmd" }
local TRIGGERS = {
    { key = "f17", fn = function() moveToDisplay("left") end,       desc = "F13+1 左ディスプレイ" },
    { key = "f18", fn = function() moveToDisplay("right") end,      desc = "F13+2 右ディスプレイ" },
    { key = "f19", fn = function() moveToDisplay("center", 61) end, desc = "F13+C 中央ディスプレイ" },
    { key = "f20", fn = resizeModerate,  desc = "F13+X 1200x750" },
    { mods = HYPER, key = "f17", fn = captureWithChoice, desc = "F13+¥ 範囲指定スクリーンショット" },
    { mods = HYPER, key = "f19", fn = moveToTop,         desc = "F13+C 2回 上ディスプレイ" },
}

triggerHotkeys = {}
for _, t in ipairs(TRIGGERS) do
    local hk = hs.hotkey.bind(t.mods or {}, t.key, t.fn)
    if hk then
        triggerHotkeys[#triggerHotkeys + 1] = hk
    else
        hs.printf("[trigger] failed to bind %s (%s)", t.key, t.desc)
    end
end

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
--
-- 右→中ボタンの変換では修飾キーを引き継ぐ。Karabiner の F13+右クリック (= Chrome での
-- F13+ミドルクリック) が Cmd+Shift を付けて送ってくるので、それを中ボタンのまま Chrome 拡張
-- (chrome-extension/link-to-new-tab) に届け、リンクを新しいタブで開かせるため。
-- newMouseEvent は修飾キーを持たないイベントを作るので、元イベントの flags を写す。
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
            e:setFlags(event:getFlags())
            return true, { e }

        elseif eventType == types.rightMouseUp then
            if not rightSwapped then return false end
            rightSwapped = false
            local e = hs.eventtap.event.newMouseEvent(types.otherMouseUp, event:location())
            e:setProperty(props.mouseEventButtonNumber, 2)
            e:setFlags(event:getFlags())
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

-- タスクバーの生存監視。
-- windowFilter の購読・8秒ポーリング・screen/app/caffeinate の各 watcher には
-- 生存確認 API が無いので、機構ごとに調べず「描画が更新され続けているか」という
-- 結果側の一点で見る (taskbar.secondsSinceRefresh)。どれが倒れてもここで捕まる。
-- 止まっていたら watcher 一式を畳んで作り直す。従来はここが倒れると無言で
-- タスクバーが凍りつき、エラーもログも出ないまま気づけなかった。
-- nil はディスプレイスリープ中 (ポーリングを意図的に停止中) なので見送る。
local TASKBAR_STALE_SEC = 30   -- ポーリング間隔8秒の3回分以上あけて誤検知を避ける
taskbarWatchdog = hs.timer.doEvery(TASKBAR_STALE_SEC, function()
    local age = taskbar.secondsSinceRefresh()
    if not age or age <= TASKBAR_STALE_SEC then return end
    hs.printf("[taskbar] no refresh for %.0fs; restarting watchers", age)
    pcall(taskbar.stop)
    pcall(taskbar.start)
end)

-- hammerspoon://reload (= hs.reload) や終了の前に OS リソースを握る
-- eventtap / timer / watcher を明示停止する。Lua ステートは作り直されるが
-- 旧インスタンスの GC が遅れると二重登録 (クリック二重変換・描画多重) を
-- 招くため、shutdownCallback で確実に畳む。
hs.shutdownCallback = function()
    if mouseSwapWatchdog then mouseSwapWatchdog:stop(); mouseSwapWatchdog = nil end
    if mouseSwapWatcher then mouseSwapWatcher:stop(); mouseSwapWatcher = nil end
    if taskbarWatchdog then taskbarWatchdog:stop(); taskbarWatchdog = nil end
    -- ホットキーは OS に登録されるので、旧インスタンスが残ると二重発火する
    if triggerHotkeys then
        for _, hk in ipairs(triggerHotkeys) do hk:delete() end
        triggerHotkeys = nil
    end
    taskbar.stop()
end
