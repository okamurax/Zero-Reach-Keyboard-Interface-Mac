// background.js からの依頼でクリップボードに書く。
// offscreen document はフォーカスを持てないので navigator.clipboard.writeText は失敗する。
// clipboardWrite 権限下の execCommand("copy") を使う (Chrome 公式サンプルと同じ方式)。
const buf = document.getElementById("buf");

chrome.runtime.onMessage.addListener((msg) => {
    if (msg?.target !== "offscreen" || msg.type !== "copy") return;
    buf.value = msg.text;
    buf.select();
    document.execCommand("copy");
});
