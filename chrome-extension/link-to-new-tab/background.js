// content.js から受けた URL を開く。newTab で渡し先だけが変わる。
//   false: クリックされたタブを遷移させる
//   true:  元タブの右隣にバックグラウンドで開く (フォーカスは元タブに残す)。
//          openerTabId を付けるので、そのタブを閉じると元タブに戻る (Chrome 標準の挙動)。
// iframe 内のクリックでもタブ全体を対象にしたいので、content script の location ではなく tabs API を使う。

chrome.runtime.onMessage.addListener((msg, sender) => {
    const tab = sender.tab;
    if (msg?.type !== "openLink" || !msg.url || !tab) return;
    if (msg.newTab) {
        chrome.tabs.create({
            url: msg.url,
            active: false,
            index: tab.index + 1,
            openerTabId: tab.id,
            windowId: tab.windowId,
        });
    } else {
        chrome.tabs.update(tab.id, { url: msg.url });
    }
});
