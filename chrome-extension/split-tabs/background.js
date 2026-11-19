// 今のタブが分割中なら解除し、そうでなければ右隣のタブと分割表示にする。
// 右隣が無い・グループや固定の状態が違うなど Chrome が分割を断る場合は何もしない。

chrome.commands.onCommand.addListener(async (command) => {
    if (command !== "toggle-split") return;
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    if (!tab) return;
    if (tab.splitViewId != null && tab.splitViewId !== -1) {
        await chrome.tabs.unsplit(tab.splitViewId);
        return;
    }
    const [right] = await chrome.tabs.query({ windowId: tab.windowId, index: tab.index + 1 });
    if (!right) return;
    await chrome.tabs.createSplit([tab.id, right.id]);
});
