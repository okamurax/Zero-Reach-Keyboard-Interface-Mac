// Cmd+Shift+クリック (Karabiner の F13+クリック) を受けたら、
// ページのスクリプトには一切渡さずに、そのリンクの URL へ遷移する。
//   左ボタン   (F13+左クリック)     → 今のタブで遷移
//   中ボタン   (F13+ミドルクリック) → 新しいタブ (バックグラウンド) で開く
// 違いは URL の渡し先だけで、イベントの握りつぶし・リンク探索は共通。
// Chrome では Hammerspoon が物理の右⇔中ボタンを入れ替えているので、中ボタンの実体は
// 物理の右ボタン。Karabiner が F13+右クリックに Cmd+Shift を付け、Hammerspoon が修飾キーを
// 引き継いだまま中ボタンに変換して届ける (hammerspoon/init.lua の mouseSwapWatcher)。
//
// document_start で window のキャプチャ段階に登録するので、ページ側のどの
// リスナーよりも先に走る (同一ターゲット・同一フェーズは登録順)。広告スクリプトは
// pointerdown / mousedown の時点でナビゲーションを奪うことが多いため、click だけでなく
// 押下〜離しの全イベントを握りつぶす。動作は最も早い pointerdown で1回だけ行う。
//
// 修飾キーを Cmd+Shift にした理由: Chrome 標準でも「新しいタブで開く」なので、
// 拡張が無効・取りこぼし時でもリンク先は開ける (その場合だけ新しい前面タブになる)。以前の Opt+Shift は
// 取りこぼすと Shift が効いて新規ウィンドウで開いてしまった。Ctrl は OS が右クリックに
// 変換するので不可。Cmd 単独は素の Cmd+クリック (バックグラウンドタブで開く) まで拡張が奪うので避けた。
//
// 【安定化の要点】
// 1. 判定は pointerdown の1回だけ。以降は修飾キーの有無を問わず全部握りつぶす (armed)。
//    Karabiner の付与した修飾が mouseup より先に離れると、修飾なしの click がページへ
//    素通りして広告やリンク遷移が走っていたため。
//    解除は「離してから DISARM_AFTER_UP_MS 後」。押している間は時間が経っても解除しない
//    (長押し後の click が素通りするため)。click で即解除もしない (ダブルクリック時に
//    2回目の click の直後に来る dblclick が素通りするため)。離しを取りこぼしても、
//    次の pointerdown で必ず判定し直すので握りっぱなしにはならない。
// 2. リンクが見つからなくても押下は握りつぶす。広告の透明オーバーレイに当たった
//    クリックを渡すとポップアンダーが開くため。
// 3. クリック対象がリンク外 (透明オーバーレイ等) なら、elementsFromPoint で
//    その座標に重なっている要素を上から順に調べ、覆いの下のリンクを拾う。
//    覆いが画面全体の透明 iframe (bunkr.cr のアルバム等。src 無し = 親と same-origin) だと
//    クリックは iframe 内の文書に届くので、frameElement で親フレームへ座標を換算しながら
//    辿り、親側の文書でも同じ探索をする。cross-origin の iframe は親を覗けないので対象外。
// 4. 遷移は background の tabs API で行う。iframe 内で拾ったリンクでも
//    その iframe ではなくタブ全体が遷移する。
// 5. 中ボタンの押下を握りつぶすので、Chrome の中ボタン押下での自動スクロールも始まらない。

const SWALLOWED = ["pointerdown", "mousedown", "pointerup", "mouseup", "click", "auxclick", "dblclick"];
const DISARM_AFTER_UP_MS = 500;   // 離してから click / auxclick / dblclick が届くまでの猶予
const BUTTON_LEFT = 0;
const BUTTON_MIDDLE = 1;

let armed = false;
let armTimer = 0;

function isTrigger(e) {
    return e.metaKey && e.shiftKey && !e.altKey && !e.ctrlKey;
}

// SVG の <a> は href が SVGAnimatedString。javascript: 等は開かない。
function linkUrlOf(a) {
    const href = typeof a.href === "string" ? a.href : a.href?.baseVal;
    if (!href) return null;
    const url = new URL(href, a.ownerDocument.baseURI).href;
    return /^(https?|file|ftp):/.test(url) ? url : null;
}

// クリック座標を、自フレームから same-origin の親フレームへ換算しながら並べる (自フレームが先頭)。
// 親の文書の elementsFromPoint には覆いの iframe 自身と、その下の要素が両方入る。
function framesAt(x, y) {
    const frames = [{ win: window, x, y }];
    let w = window;
    while (w !== w.top) {
        let fe = null;
        try { fe = w.frameElement; } catch { /* cross-origin */ }
        if (!fe) break;
        const r = fe.getBoundingClientRect();
        x += r.left + fe.clientLeft;
        y += r.top + fe.clientTop;
        w = w.parent;
        frames.push({ win: w, x, y });
    }
    return frames;
}

function findLinkUrl(e) {
    // composedPath で Shadow DOM 内のリンクも拾う
    for (const node of e.composedPath()) {
        if (node instanceof Element && node.localName === "a") {
            const url = linkUrlOf(node);
            if (url) return url;
        }
    }
    // 透明オーバーレイ越し: 座標に重なる要素を前面から順に。親フレームの要素は別 realm なので instanceof は使わない
    for (const f of framesAt(e.clientX, e.clientY)) {
        for (const el of f.win.document.elementsFromPoint(f.x, f.y)) {
            const a = el.closest("a[href]");
            if (a) {
                const url = linkUrlOf(a);
                if (url) return url;
            }
        }
    }
    return null;
}

function disarm() {
    armed = false;
    clearTimeout(armTimer);
}

function onEvent(e) {
    if (e.type === "pointerdown") {
        if (e.button !== BUTTON_LEFT && e.button !== BUTTON_MIDDLE) { disarm(); return; }
        if (!isTrigger(e)) { disarm(); return; }
        armed = true;
        clearTimeout(armTimer);

        e.preventDefault();
        e.stopImmediatePropagation();

        const url = findLinkUrl(e);
        if (url) {
            // 拡張を再読み込みした後、リロードしていない古いタブでは文脈が切れて例外になる
            try {
                chrome.runtime.sendMessage({ type: "openLink", url, newTab: e.button === BUTTON_MIDDLE });
            } catch (err) {
                console.warn("[link-to-new-tab] タブをリロードしてください:", err);
            }
        }
        return;
    }

    if (!armed) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    if (e.type === "pointerup" || e.type === "mouseup") {
        clearTimeout(armTimer);
        armTimer = setTimeout(disarm, DISARM_AFTER_UP_MS);
    }
}

for (const type of SWALLOWED) {
    window.addEventListener(type, onEvent, { capture: true });
}
