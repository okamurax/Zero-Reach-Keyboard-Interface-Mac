// Cmd+Shift+クリック (Karabiner の F13+クリック) を受けたら、
// ページのスクリプトには一切渡さずに URL をコピー → 新しいタブで開く。
//
// document_start で window のキャプチャ段階に登録するので、ページ側のどの
// リスナーよりも先に走る (同一ターゲット・同一フェーズは登録順)。広告スクリプトは
// pointerdown / mousedown の時点でナビゲーションを奪うことが多いため、click だけでなく
// 押下〜離しの全イベントを握りつぶす。動作は最も早い pointerdown で1回だけ行う。
//
// 修飾キーを Cmd+Shift にした理由: Chrome 標準でも「新しいタブで開く」なので、
// 拡張が無効・取りこぼし時でもタブで開く (その場合だけ前面タブになる)。以前の Opt+Shift は
// 取りこぼすと Shift が効いて新規ウィンドウで開いてしまった。Ctrl は OS が右クリックに
// 変換するので不可。Cmd 単独は素の Cmd+クリックまで拡張が奪いクリップボードを毎回上書きするので避けた。
//
// 【安定化の要点】
// 1. 判定は pointerdown の1回だけ。以降 click が終わるまでは修飾キーの有無を問わず
//    全部握りつぶす (armed)。Karabiner の付与した修飾が mouseup より先に離れると、
//    修飾なしの click がページへ素通りして広告やリンク遷移が走っていたため。
// 2. リンクが見つからなくても押下は握りつぶす。広告の透明オーバーレイに当たった
//    クリックを渡すとポップアンダーが開くため。
// 3. クリック対象がリンク外 (透明オーバーレイ等) なら、elementsFromPoint で
//    その座標に重なっている要素を上から順に調べ、覆いの下のリンクを拾う。
// 4. クリップボードへのコピーは background (offscreen document) に任せる。
//    サイトが Permissions-Policy で clipboard-write を禁止していると (bunkr.cr 等)、
//    ページ内の content script からは Clipboard API が弾かれるため。

const SWALLOWED = ["pointerdown", "mousedown", "pointerup", "mouseup", "click", "auxclick", "dblclick"];
const ARM_TIMEOUT_MS = 1500;   // click が来ないまま終わった場合 (ドラッグ等) の解除保険

let armed = false;
let armTimer = 0;

function isTrigger(e) {
    return e.button === 0 && e.metaKey && e.shiftKey && !e.altKey && !e.ctrlKey;
}

// SVG の <a> は href が SVGAnimatedString。javascript: 等は開かない。
function linkUrlOf(a) {
    const href = typeof a.href === "string" ? a.href : a.href?.baseVal;
    if (!href) return null;
    const url = new URL(href, document.baseURI).href;
    return /^(https?|file|ftp):/.test(url) ? url : null;
}

function findLinkUrl(e) {
    // composedPath で Shadow DOM 内のリンクも拾う
    for (const node of e.composedPath()) {
        if (node instanceof Element && node.localName === "a") {
            const url = linkUrlOf(node);
            if (url) return url;
        }
    }
    // 透明オーバーレイ越し: 座標に重なる要素を前面から順に
    for (const el of document.elementsFromPoint(e.clientX, e.clientY)) {
        const a = el.closest("a[href]");
        if (a) {
            const url = linkUrlOf(a);
            if (url) return url;
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
        if (e.button !== 0) return;
        if (!isTrigger(e)) { disarm(); return; }
        armed = true;
        clearTimeout(armTimer);
        armTimer = setTimeout(disarm, ARM_TIMEOUT_MS);

        e.preventDefault();
        e.stopImmediatePropagation();

        const url = findLinkUrl(e);
        if (url) {
            // 拡張を再読み込みした後、リロードしていない古いタブでは文脈が切れて例外になる
            try {
                chrome.runtime.sendMessage({ type: "openInNewTab", url });
            } catch (err) {
                console.warn("[link-to-new-tab] タブをリロードしてください:", err);
            }
        }
        return;
    }

    if (!armed) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    if (e.type === "click") disarm();
}

for (const type of SWALLOWED) {
    window.addEventListener(type, onEvent, { capture: true });
}
