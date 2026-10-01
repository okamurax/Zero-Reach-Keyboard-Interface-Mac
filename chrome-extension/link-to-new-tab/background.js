// content.js から受けた URL を、元タブの右隣にバックグラウンドで開く (フォーカスは元タブに残す)。
// openerTabId を付けるので、そのタブを閉じると元タブに戻る (Chrome 標準の挙動)。
//
// クリップボードへのコピーもここで行う。content script はページの Permissions-Policy に
// 縛られる (bunkr.cr は clipboard-write を禁止) が、拡張自身の offscreen document は縛られない。
// service worker には DOM も Clipboard API も無いので offscreen document を経由する。

let creatingOffscreen = null;

async function ensureOffscreen() {
    if (await chrome.offscreen.hasDocument()) return;
    // 連続クリックで createDocument が二重に走ると例外になるので、作成中の Promise を共有する
    creatingOffscreen ??= chrome.offscreen.createDocument({
        url: "offscreen.html",
        reasons: ["CLIPBOARD"],
        justification: "リンクのアドレスをクリップボードにコピーする",
    }).finally(() => { creatingOffscreen = null; });
    await creatingOffscreen;
}

async function copyToClipboard(text) {
    try {
        await ensureOffscreen();
        await chrome.runtime.sendMessage({ target: "offscreen", type: "copy", text });
    } catch (err) {
        console.warn("[link-to-new-tab] copy failed:", err);
    }
}

chrome.runtime.onMessage.addListener((msg, sender) => {
    if (msg?.type !== "openInNewTab" || !msg.url) return;
    const tab = sender.tab;
    chrome.tabs.create({
        url: msg.url,
        active: false,
        ...(tab ? { index: tab.index + 1, openerTabId: tab.id, windowId: tab.windowId } : {}),
    });
    copyToClipboard(msg.url);
});
