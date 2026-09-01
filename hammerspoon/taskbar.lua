-- 画面下に貼り付くWin風タスクバー
-- ディスプレイごとに「そのディスプレイ上のウィンドウ一覧」を表示し、
-- 左クリックでアクティブ化する。クローズ操作は持たない
-- (ボタン内に × を置くとアプリ切替時に踏むため。理由は下の「× の廃止」参照)。
--
-- 設計メモ:
--   * hs.canvas をディスプレイごとに1枚ずつ作る
--   * hs.window.filter のサブスクリプションで再描画
--   * 全イベントは scheduleRefresh で 200ms にまとめて主スレッド負荷を抑える
--     (連射継続時も最長1秒で必ずflushするmax-wait付きdebounce)
--   * 8秒間隔のフォールバック refresh は filter が取りこぼす Adobe/Parallels 対策

local M = {}

local BAR_H        = 43
-- ウィンドウ配置側 (init.lua の movetodisplay) がバー高さを差し引くために公開する。
-- ここが唯一の定義。呼び出し側や Karabiner の URL に値を複製しないこと
-- (複製すると BAR_H 変更時に無言でウィンドウがバーに潜り込む)。
M.BAR_H = BAR_H
-- hs.canvas のウィンドウは上端に↕(縦リサイズカーソル)が出る (リサイズ無効化APIが無い)。
-- ウィンドウを上に CURSOR_PAD だけ広げ、↕の判定縁を可視バーの外(透明帯)へ逃がす。
-- 中身は transformation で同量下げ位置不変。透明帯はクリックを奪うため、最小限の値にし、
-- かつ click 時は y-guard で「帯のクリックは無視」して誤アプリ切替を防ぐ。
-- matrix API が無い環境では 0 にフォールバック (タスクバーを壊さない)。
local CURSOR_PAD   = (hs.canvas.matrix and hs.canvas.matrix.translate) and 4 or 0
local ITEM_W       = 210   -- ボタン幅の最大値 (ウィンドウが少ないとき)
local MIN_ITEM_W   = 60    -- ボタン幅の最小値 (圧縮の下限。アイコン+タイトル数文字が残る幅)
local ITEM_GAP     = 4
local ITEM_PAD     = 6
-- アイコン一辺。macOS のアプリアイコンは画像自体に約10%の透明余白を持つ
-- (1024px キャンバスに 824px の角丸) ため、見た目の絵柄はこの値より一回り小さい。
-- × を廃止したので「× と重ならない」制約は消えたが、上限は MIN_ITEM_W に縛られたまま。
-- 圧縮の下限幅ではタイトルの取り分が itemW - ICON_W - 12 = 16px しか残らず、
-- ここを大きくするとタイトルが完全に消える。上げるなら MIN_ITEM_W も一緒に上げること。
local ICON_W       = 32
local FONT_SIZE    = 13
local FONT_NAME    = ".AppleSystemUIFont"
local BG_COLOR     = { red = 0.10, green = 0.10, blue = 0.10, alpha = 0.92 }
local ITEM_BG      = { red = 0.20, green = 0.20, blue = 0.20, alpha = 1.0 }
local ITEM_BG_MIN  = { red = 0.14, green = 0.14, blue = 0.14, alpha = 1.0 }
-- 純白 (0.95) は暗い背景で滲んで見えるので、VSCode Dark+ の editor.foreground
-- (#D4D4D4 = 212/255 ≒ 0.83) に合わせて少しだけグレーを混ぜている。
local TEXT_COLOR   = { white = 0.83 }
local TEXT_MIN     = { white = 0.55 }

-- バーに出さないアプリ (bundleID)。
-- 常駐して画面端に貼り付くタイプのアプリは、窓としては標準扱い (isStandard() が true)
-- なので snapshotWindow の一般則では落とせない。ここで名指しで除外する。
local EXCLUDED_BUNDLES = {
    ["org.hammerspoon.Hammerspoon"] = true,  -- 自分自身 (タスクバーの canvas を含む)
    ["com.apptorium.SideNotes"]     = true,  -- 常時表示のサイドメモ。切替対象にならない
}

-- screenId -> { canvas, w, lastSig, lastDropped, items = { {win, x1, x2}, ... } }
--   items の x1..x2 がクリック領域 (canvas ローカル座標)。ボタン全幅がそのまま当たり判定。
local bars = {}
local refreshTimer
local windowFilter
local refreshDebounce
local lastScreenSig = ""
local refresh -- forward declaration

-- 空き領域のダブルクリック判定用 (同じバー上で連続クリックされたか)
-- macOS 標準のダブルクリック間隔(既定〜0.5秒)に合わせる
local DBLCLICK_SEC = 0.5
local lastEmptyClick = { id = nil, at = 0 }

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
local POLL_INTERVAL = 8
local pollingActive = false
local function startPoll()
    pollingActive = true
    if refreshTimer then return end
    refreshTimer = hs.timer.doEvery(POLL_INTERVAL, scheduleRefresh)
end
local function stopPoll()
    pollingActive = false
    if refreshTimer then refreshTimer:stop(); refreshTimer = nil end
end

-- 生存監視用。refresh が最後に完走した時刻からの経過秒を返す。
--
-- windowFilter の購読 / refreshTimer / screen・app・caffeinate の各 watcher には
-- どれも生存確認 API が無く、個別に「生きているか」を問うことができない。
-- そこで機構ごとに調べるのをやめ、「結果として描画が更新され続けているか」という
-- 単一の観測点に集約する。どれが倒れてもここが進まなくなるので一度に検出できる。
--
-- ディスプレイスリープ中はポーリングを意図的に止めており更新が無いのが正常なので、
-- その間は nil (=判定不能) を返して監視側に見送らせる。
local lastRefreshAt = 0
function M.secondsSinceRefresh()
    if not pollingActive then return nil end
    return hs.timer.secondsSinceEpoch() - lastRefreshAt
end

-- 現在のスクリーンID集合を表す文字列 (構成変化検出用)
local function currentScreenSig()
    local ids = {}
    for _, s in ipairs(hs.screen.allScreens()) do ids[#ids + 1] = s:id() end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- テキスト幅の測定専用 canvas (表示しない)。
-- minimumTextSize は canvas 要素のフォント属性を使って測るので、実際に描くのと
-- 同じ FONT_NAME / FONT_SIZE を持つ要素をひとつだけ載せておく。
-- 描画用の bar.canvas を使わないのは、renderBar が replaceElements で要素を作り直す
-- 途中で測る必要があり、測定対象の要素番号が描画順に依存してしまうため。
local measureCanvas
local function ensureMeasureCanvas()
    if measureCanvas then return measureCanvas end
    local c = hs.canvas.new({ x = 0, y = 0, w = 1, h = 1 })
    if not c then return nil end   -- 測れない環境では折り返し判定を諦めて1行に倒す
    c[1] = { type = "text", text = "", textFont = FONT_NAME, textSize = FONT_SIZE }
    measureCanvas = c
    return measureCanvas
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

-- ウィンドウ1枚ぶんの属性を1回だけ読み取り、素の Lua テーブルに写して返す。
-- 出すべきでない窓は nil を返す (旧 isTaskable の判定をここに統合)。
--
-- なぜスナップショットにするか:
--   AX の問い合わせは1回ごとに hs.window.timeout(1) の上限まで待つ可能性があり、
--   詰まったアプリが1つでもいると「往復回数 × 最大1秒」が主スレッドの停止時間に
--   なる。以前は同じ属性を判定・ソート・描画で別々に引いており、application() は
--   窓あたり3回、id() に至ってはソート比較関数の中から O(n log n) 回呼ばれていた。
--   1パスに畳むことで往復回数を窓数に比例する分だけに抑える。
--
-- これは refresh 1回ごとに作って捨てる使い捨ての値であって、永続キャッシュでは
-- ないこと。窓の状態を跨いで持つと「閉じたのに消えない窓」のような腐り方をする。
local function snapshotWindow(win)
    local app = win:application()
    if not app then return nil end
    local bid = app:bundleID()
    if bid and EXCLUDED_BUNDLES[bid] then return nil end

    local isHidden = app:isHidden() or false
    local title = win:title() or ""

    -- 出す/出さないの判定。最小化中もタスクバーに残す
    -- (クリックで復元する Win 風挙動のため)。
    local taskable = win:isStandard()
    if not taskable and bid == "com.apple.finder" and isHidden then
        -- Finder は app:hide() 中に win:isStandard() が false に変わるため特例で許可。
        -- 無題ウィンドウ (デスクトップ用) は除外したいので title 必須。
        taskable = (title ~= "")
    end
    if not taskable then
        -- Adobe Bridge のように、AX 的な標準ウィンドウを作らないアプリへの特例。
        -- Bridge のメイン窓は role=AXLayoutArea / subrole=AXFloatingWindow で、
        -- isStandard() が false になるためここまで落ちてくる。
        -- ただし macOS 自身が AXWindows に載せている実体であり、実測で
        -- id / title / frame / screen / AXRaise / AXCloseButton が全て揃っている
        -- (= バーの描画もクリックによるアクティブ化も成立する) ので出す。
        --
        -- 条件を「role が AXWindow ですらない」に絞っているのはパレット類を巻き込まないため。
        -- Adobe 系のフローティングパレットは role=AXWindow + subrole=AXFloatingWindow なので
        -- この条件には該当せず、従来通り除外される。無題の要素も除くので title は必須。
        -- role() は標準ウィンドウでは不要なので、ここまで落ちた窓だけで引く。
        local role = win:role()
        taskable = (role ~= nil and role ~= "AXWindow" and title ~= "")
    end
    if not taskable then return nil end

    local screen = win:screen()
    if not screen then return nil end

    return {
        win      = win,
        -- id は signature とソートの第2キーに使う。nil を返す窓が居ても
        -- テーブル添字エラーで refresh 全体を落とさないよう 0 に倒す
        -- (順序が多少乱れるだけで、描画もクリックも成立する)。
        id       = win:id() or 0,
        screen   = screen,
        screenId = screen:id(),
        appName  = app:name() or "",
        bundle   = bid,
        title    = title,
        -- Finder の app:hide() もグレーアウト扱い (個別 minimize は出来ないため)
        isMin    = win:isMinimized() or isHidden,
    }
end

-- ディスプレイ毎にウィンドウをグループ化
local function groupWindowsByScreen()
    local map = {}
    for _, win in ipairs(hs.window.allWindows()) do
        -- 窓1枚の AX 例外で refresh 全体を落とさない。終了しかけの窓を掴むのは
        -- 日常的に起きるが、そこで抜けるとバーが丸ごと更新されなくなり、復旧は
        -- init.lua の30秒ウォッチドッグ待ちになる。読めない窓だけ捨てて続行し、
        -- 次の refresh で拾い直す (AXタイムアウト時と同じ「その窓が一瞬消える」で済ませる)。
        local ok, e = pcall(snapshotWindow, win)
        if not ok then
            hs.printf("[taskbar] window skipped: %s", tostring(e))
        elseif e then
            local id = e.screenId
            map[id] = map[id] or { screen = e.screen, wins = {} }
            table.insert(map[id].wins, e)
        end
    end
    -- allWindows() は z-order (最近フォーカスが先頭) を返すため、フォーカスのたびに
    -- 並びが変わりアクティブ窓が左へ飛ぶ。アプリ名 → ウィンドウID の2段で固定する。
    --
    -- 第1キーをアプリ名にしているのは、同じアプリの窓 (VSCode を2つ開いた等) を
    -- 隣り合わせて探しやすくするため。第2キーのウィンドウIDは生成順で安定なので、
    -- 同じアプリ内の並びもフォーカスでは動かない。
    -- 比較関数は snapshot の素の値だけを見る。ここで win:id() や app:name() を
    -- 呼ぶと O(n log n) 回の AX 問い合わせになる (デコレート-ソート)。
    for _, g in pairs(map) do
        table.sort(g.wins, function(a, b)
            if a.appName ~= b.appName then return a.appName < b.appName end
            return a.id < b.id
        end)
    end
    return map
end

-- 1枚のバーを描画
-- wins は snapshotWindow が作った素のテーブルの配列。ここでは AX を一切引かない
-- (引くと refresh 1回の AX 往復が窓数ぶん増え、詰まったアプリの待ち時間が積み上がる)。
-- 表示状態が前回と完全一致なら canvas を触らずに早期return (差分render)。
local function renderBar(bar, wins)
    -- ウィンドウ数に応じてボタン幅を圧縮し、できるだけ全ウィンドウを収める
    -- (Windowsタスクバー風)。幅は MIN_ITEM_W〜ITEM_W にクランプ。
    -- MIN_ITEM_W でも収まらない数のときのみ溢れ、溢れた分はログに出す。
    local n = #wins
    local itemW = ITEM_W
    if n > 0 then
        local avail = bar.w - 2 * ITEM_PAD - (n - 1) * ITEM_GAP
        itemW = math.max(MIN_ITEM_W, math.min(ITEM_W, math.floor(avail / n)))
    end

    -- 表示対象だけ先に確定 (signature と描画ループで共有)
    local visible = {}
    local x0 = ITEM_PAD
    for _, e in ipairs(wins) do
        if x0 + itemW > bar.w - ITEM_PAD then break end
        -- 無題ウィンドウはアプリ名で代用する
        local title = (e.title ~= "") and e.title or e.appName
        visible[#visible + 1] = {
            win = e.win,
            id = e.id,
            title = title,
            isMin = e.isMin,
            -- 取得失敗 (起動直後) は nil。後から取得できたら signature が変わり再描画される
            icon = getAppIcon(e.bundle),
        }
        x0 = x0 + itemW + ITEM_GAP
    end
    local dropped = n - #visible

    -- signature: barサイズ + 各item状態。前回と同じなら描画スキップ
    -- アイコン有無も含める (起動直後 nil→取得成功 への遷移で再描画させる)
    local sigParts = { bar.w }
    for _, v in ipairs(visible) do
        sigParts[#sigParts + 1] = v.id .. ":" .. v.title .. ":" ..
            (v.isMin and "m" or "_") .. (v.icon and "i" or "_")
    end
    local sig = table.concat(sigParts, "|")
    if bar.lastSig == sig then return end
    bar.lastSig = sig

    -- 圧縮しても溢れた分は無言で消さず、変化時のみログに残す (no-silent-cap)
    if dropped > 0 and bar.lastDropped ~= dropped then
        hs.printf("[taskbar] %d window(s) hidden: screen too narrow even at min width", dropped)
    end
    bar.lastDropped = dropped

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
        local win, isMin, title = v.win, v.isMin, v.title

        local bgColor = isMin and ITEM_BG_MIN or ITEM_BG

        -- アイテム背景
        canvas[#canvas + 1] = {
            type = "rectangle",
            action = "fill",
            fillColor = bgColor,
            roundedRectRadii = { xRadius = 4, yRadius = 4 },
            frame = { x = x, y = 4, w = itemW, h = BAR_H - 8 },
        }

        -- アイコン (visible 確定時に取得済み。signature と整合させ二重取得を避ける)
        if v.icon then
            canvas[#canvas + 1] = {
                type = "image",
                image = v.icon,
                frame = { x = x + 4, y = (BAR_H - ICON_W) / 2, w = ICON_W, h = ICON_W },
            }
        end

        -- タイトル。1行に収まらないものは2行に折り返す (… による省略はしない)。
        -- 「切れていることが分かる」より「読める文字数」を優先する。… は1文字分の幅を
        -- 食うだけで、読めない部分の情報は結局得られないため。
        --
        -- charWrap を使う理由: 日本語には単語境界が無く wordWrap だと英字部分だけが
        -- 手前で折れて1行目の右に余白ができる。文字単位で詰めた方が字数が稼げる。
        -- なお truncateTail は枠を高くしても1行のままなので、折り返しと … は両立しない
        -- (実測確認済み)。
        --
        -- 高さは measureCanvas の実測で切り替える。canvas には垂直センタリングが無く、
        -- 2行分の枠に1行のタイトルを入れると上寄せになってアイコンと揃わないため、
        -- 1行に収まるなら1行分の枠を使い、どちらの場合もバー高の中央へ置く。
        local titleW = math.max(0, itemW - ICON_W - 12)
        local mc = ensureMeasureCanvas()
        local size = mc and titleW > 0 and mc:minimumTextSize(1, title) or nil
        local lineH = (size and size.h) or (FONT_SIZE + 3)
        -- minimumTextSize は約4pt の誤差があるとドキュメントに明記されている。
        -- 1行と誤判定すると charWrap では2行目が枠外に出て無言で消えるので、
        -- 判定はその誤差分だけ折り返し側へ倒しておく。
        local wrapped = (size ~= nil) and (size.w > titleW - 4)
        local titleH = wrapped and (lineH * 2) or lineH
        canvas[#canvas + 1] = {
            type = "text",
            text = title,
            textColor = isMin and TEXT_MIN or TEXT_COLOR,
            textFont = FONT_NAME,
            textSize = FONT_SIZE,
            textLineBreak = "charWrap",
            frame = {
                x = x + 4 + ICON_W + 4,
                y = math.floor((BAR_H - titleH) / 2),
                w = titleW,
                h = titleH,
            },
        }

        -- 【× の廃止】以前はここに幅 21px の × を描いてクローズさせていたが、
        -- アプリ切替のクリックで誤って踏む事故が続いたため廃止した。
        -- CLOSE_W が固定なのに itemW は窓数に応じて MIN_ITEM_W まで縮むので、
        -- 窓が増えるほどボタン右端の当たり判定に占める × の割合が上がり
        -- (210px で 10%、下限 60px では約 1/3)、狭いときほど誤爆しやすかった。
        -- ホバー時だけ出す案もあるが、出た瞬間にポインタが載っている位置に描かれる以上
        -- 踏む事故自体は消えないので採らない。クローズはアプリ側の ⌘W / ⌘Q を使う。
        table.insert(bar.items, {
            win = win,
            x1 = x, x2 = x + itemW,
        })

        x = x + itemW + ITEM_GAP
    end
end

-- バーを必要なら作成、不要なら破棄、全部renderする
refresh = function()
    local grouped = groupWindowsByScreen()

    -- 全ディスプレイに対してバーを出す (ウィンドウが無くても空バーを表示)
    local liveScreens = {}
    for _, screen in ipairs(hs.screen.allScreens()) do
        local id = screen:id()
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
        -- full と vis の差から Dock 領域を避けてバーを置く。
        -- 下端差(=下配置Dock)の上にバーを乗せ、左右の差(=左右配置Dock)分は
        -- バーの x/幅を visibleFrame に合わせて重ならないようにする。
        -- (下配置Dock時は vis.x==full.x / vis.w==full.w なので従来と同じ全幅)
        local dockBottom = (full.y + full.h) - (vis.y + vis.h)
        local barX = vis.x
        local barY = full.y + full.h - dockBottom - BAR_H
        local barW = vis.w

        local bar = bars[id]
        if not bar then
            local canvas = hs.canvas.new({ x = barX, y = barY - CURSOR_PAD, w = barW, h = BAR_H + CURSOR_PAD })
            canvas:level(hs.canvas.windowLevels.dock - 1)
            canvas:behavior({ "canJoinAllSpaces", "stationary" })
            canvas:clickActivating(false)
            -- 中身を CURSOR_PAD 下げ、広げた窓内で元位置に描く (↕縁逃がし)
            if CURSOR_PAD > 0 then
                canvas:transformation(hs.canvas.matrix.translate(0, CURSOR_PAD))
            end
            canvas:mouseCallback(function(_, msg, _, x, y)
                if msg ~= "mouseDown" then return end
                -- 可視バー上端の透明帯(y < CURSOR_PAD ↕逃がし用)へのクリックは無視。
                -- でないと最大化アプリのシークバー等を触った時に誤ってアプリ切替してしまう。
                if y < CURSOR_PAD then return end
                -- ターゲットアプリ終了直後の AX 例外などで callback 全体が死ぬのを防ぐ
                local ok, err = pcall(function()
                    local b = bars[id]
                    if not b then return end
                    for _, item in ipairs(b.items) do
                        if x >= item.x1 and x <= item.x2 then
                            local win = item.win
                            if not win then return end
                            local app = win:application()
                            -- 前回 render 以降に閉じられたウィンドウ: 無言で失敗させず
                            -- バーを更新して古い行を消す
                            if not app then scheduleRefresh(); return end
                            local isHidden = app:isHidden()
                            -- トグル廃止: 常に「最前面 + フォーカス」だけにする。
                            -- (最小化するとタスクバーから消えるアプリが多く、最小化での
                            --  管理が現実的でないため。最小化/hide 中ならまず復元する)
                            if isHidden then app:unhide() end
                            if win:isMinimized() then win:unminimize() end
                            win:focus()
                            win:raise()
                            return
                        end
                    end
                    -- どのアイテムにも当たらなかった = 空き領域。
                    -- 同じバー上で DBLCLICK_SEC 以内に2回目 → 「デスクトップを表示」をトグル。
                    -- 最小化と違いウィンドウは非最小化のまま画面外へ退避するだけなので、
                    -- allWindows() に残りタスクバーから消えない (要望: 最小化せずデスクトップ表示)。
                    -- キー送出(F11)は単一CGEventSource死の影響を受けるため使わず、
                    -- hs.spaces のAPI(キー送出なし)で開閉する。
                    local now = hs.timer.secondsSinceEpoch()
                    if lastEmptyClick.id == id and (now - lastEmptyClick.at) < DBLCLICK_SEC then
                        lastEmptyClick.at = 0  -- 連続トリガ防止 (3クリック目で再発火しない)
                        hs.spaces.toggleShowDesktop()
                    else
                        lastEmptyClick.id = id
                        lastEmptyClick.at = now
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
            bar.canvas:frame({ x = barX, y = barY - CURSOR_PAD, w = barW, h = BAR_H + CURSOR_PAD })
            bar.w = barW
        end

        renderBar(bar, g.wins)
    end

    -- 完走した時だけ更新する (途中で AX 例外等が出たら進めない = 監視側が検知する)
    lastRefreshAt = hs.timer.secondsSinceEpoch()
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
    if measureCanvas then measureCanvas:delete(); measureCanvas = nil end
end

return M
