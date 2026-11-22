// 名前の変更の中身 (DownloadsShelf の「名前を変更」)。画面に依存しないので tests/ のファズから直接呼ぶ。
//
// ファイルを失わないための手順:
// - 変更先は必ず同じフォルダ。renamex_np 1 回で名前だけを差し替える (コピー+削除はしない)。
//   失敗しても元のファイルはそのまま残り、途中の状態は存在しない
// - RENAME_EXCL で、変更先に同名のファイルがあれば上書きせず失敗させる。事前に有無を調べてから変える方式と違い、
//   調べてから変えるまでの間に同名ができても上書きしない
// - 大文字小文字・濁点の合成/分解だけが違う名前は、APFS では同じファイルを指すので RENAME_EXCL が「既にある」で
//   失敗する。変更先が元と同じファイル (同じデバイス・inode) だと確かめた時だけ、RENAME_EXCL 無しで変える
// - 名前は区切り文字 (/ と :)・先頭の .・改行などの制御文字・255 バイト超を拒否する (: は Finder では / に見え、. 始まりは隠しファイルになる)

import Foundation

enum RenameOutcome: Equatable {
    case unchanged            // 元と同じ名前
    case renamed(URL)         // 変えた。新しい場所
    case rejected(String)     // 名前が使えない (何もしていない)
    case failed(String)       // 変えられなかった (何もしていない)
}

func renameInPlace(_ src: URL, to name: String) -> RenameOutcome {
    if name == src.lastPathComponent { return .unchanged }
    if let problem = renameInvalidReason(name) { return .rejected(problem) }
    let dst = src.deletingLastPathComponent().appendingPathComponent(name)
    var result = renamex_np(src.path, dst.path, UInt32(RENAME_EXCL))
    var err = errno
    if result != 0 && err == EEXIST && isSameFile(src, dst) {
        result = renamex_np(src.path, dst.path, 0)
        err = errno
    }
    if result != 0 {
        return .failed(err == EEXIST ? "同じ名前のファイルが既にあります。" : String(cString: strerror(err)))
    }
    return .renamed(dst)
}

func renameInvalidReason(_ name: String) -> String? {
    if name.isEmpty { return "名前が空です。" }
    if name.contains("/") || name.contains(":") { return "「/」と「:」は使えません。" }
    if name.hasPrefix(".") { return "「.」で始まる名前は隠しファイルになるため使えません。" }
    // 改行などの制御文字 (NUL を含む)。NUL 以降は C の文字列として切り捨てられて別の名前になり、改行入りの名前は
    // シェルフからターミナルへ落とした時に、貼り付けたパスの途中で Enter として働いてしまう
    if name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) { return "改行などの制御文字は使えません。" }
    if name.utf8.count > 255 { return "名前が長すぎます。" }
    return nil
}

func isSameFile(_ a: URL, _ b: URL) -> Bool {
    var sa = stat(), sb = stat()
    guard lstat(a.path, &sa) == 0, lstat(b.path, &sb) == 0 else { return false }
    return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
}
