// DownloadsShelf の名前変更 (downloads-shelf/RenameFile.swift の renameInPlace) のファズ。
// 一時フォルダに中身の違うファイルを何個か作り、そのうち 1 つを乱数で作った名前に変えて、次を確かめる:
//   1. ファイルは消えない・上書きされない (変更の前後で、フォルダ内の中身の集まりが同じ)
//   2. 変えられなかった時 (unchanged / rejected / failed) は、名前も 1 文字も変わっていない
//   3. 変えた時は、指定した名前 (濁点などの合成/分解の違いは同じとみなす) で元の中身が読め、ファイル数は変わらない
//   4. 結果が「名前の決まり」と「他のファイルとの衝突」から期待されるものと一致する
//      (使えない名前 → rejected / 他のファイルと同じ名前扱い → failed / それ以外 → renamed)
// tests/run.sh がビルドして回す。回数と乱数の種は FUZZ_N / FUZZ_SEED (既定 3000 回、種 1)。

import Foundation

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func pick<T>(_ a: [T]) -> T { a[int(a.count)] }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
}

// 名前の部品。APFS が同じ名前とみなす組 (大文字小文字、濁点・アクセントの合成/分解) を多めに混ぜる
let pieces: [String] = [
    "a", "A", "b", "B", "report", "Report", "REPORT", "IMG_0001", "img_0001",
    "が", "か\u{3099}", "パ", "ハ\u{309A}", "é", "e\u{301}", "É", "Å", "A\u{30A}", "ß", "ﬁ",
    "写真", "資料", "😀", "👨‍👩‍👧", " ", "  ", "-", "_", "(1)", "#", "%", "'", "\"", "\\",
    ".", "..", ".txt", ".TXT", ".pdf", ".tar.gz", "/", ":", "\n", "\t", "\u{0}", "\u{200B}", "\u{FEFF}",
]

func randomName(_ r: inout SplitMix64) -> String {
    var s = ""
    for _ in 0..<(1 + r.int(5)) { s += r.pick(pieces) }
    if r.chance(0.05) {  // 255 バイト前後の長い名前 (多バイト文字で境目をまたぐ)
        let unit = r.pick(["a", "あ", "é", "😀"])
        let target = 250 + r.int(10)
        while s.utf8.count + unit.utf8.count <= target { s += unit }
    }
    return s
}

// APFS (大文字小文字を区別しない設定) で同じ名前とみなされるかの近似: 正規化をそろえて大文字小文字を畳む
func apfsKey(_ s: String) -> String {
    s.decomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
}

func expectedInvalid(_ name: String) -> Bool {
    name.isEmpty || name.contains("/") || name.contains(":") || name.hasPrefix(".") || name.utf8.count > 255
        || name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
}

// フォルダの中身: 実際の名前 (Unicode の表し方そのまま) → 中身。
// FileManager は一覧で先頭の U+FEFF を落とし、読む時は名前を分解形に変えるため、readdir / open で直接読む
func snapshot(_ dir: URL) -> [String: String] {
    var out: [String: String] = [:]
    guard let d = opendir(dir.path) else { return out }
    defer { closedir(d) }
    while let e = readdir(d) {
        let name = withUnsafeBytes(of: e.pointee.d_name) { raw in
            String(decoding: raw.prefix(Int(e.pointee.d_namlen)), as: UTF8.self)
        }
        if name == "." || name == ".." { continue }
        out[name] = readContent(dir.path + "/" + name) ?? ""
    }
    return out
}

func readContent(_ path: String) -> String? {
    let fd = open(path, O_RDONLY)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var buf = [UInt8](repeating: 0, count: 256)
    let n = read(fd, &buf, buf.count)
    return String(decoding: buf.prefix(max(n, 0)), as: UTF8.self)
}

// 名前を Unicode の表し方そのままで作る。FileManager.createFile は名前を分解形 (NFD) に変えてから作るため使わない
// (DownloadsShelf に並ぶファイルはブラウザなどが作るので、合成形のまま置かれていることがある)
func createExact(_ dir: URL, _ name: String, _ content: String) -> Bool {
    let fd = open(dir.path + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o644)
    guard fd >= 0 else { return false }
    let bytes = Array(content.utf8)
    _ = write(fd, bytes, bytes.count)
    close(fd)
    return true
}

func show(_ s: String) -> String {
    s.unicodeScalars.map { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F ? String($0) : String(format: "\\u{%X}", $0.value) }.joined()
}

func scalarsEqual(_ a: String, _ b: String) -> Bool { Array(a.unicodeScalars) == Array(b.unicodeScalars) }

@main
struct RenameFuzz {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        let n = Int(env["FUZZ_N"] ?? "") ?? 3000
        let seed = UInt64(env["FUZZ_SEED"] ?? "") ?? 1
        var r = SplitMix64(state: seed)
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rename-fuzz-\(getpid())")
        try? FileManager.default.removeItem(at: root)
        var failures = 0
        var counts: [String: Int] = [:]

        for i in 0..<n {
            let dir = root.appendingPathComponent("\(i)")
            try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 中身の違うファイルを 1〜4 個。改行などの制御文字入りの名前も作る (新しく付ける名前としては拒否するが、
            // ブラウザ等が作ったファイルとしては置かれ得る)。作れない名前・同じ名前扱いになる名前は飛ばす
            var made: [String] = []
            for k in 0..<(1 + r.int(4)) {
                let name = randomName(&r)
                guard !name.isEmpty, !name.contains("/"), !name.contains("\u{0}"), !name.hasPrefix("."),
                      name.utf8.count <= 255,
                      !made.contains(where: { apfsKey($0) == apfsKey(name) }) else { continue }
                if createExact(dir, name, "file-\(k)") { made.append(name) }
            }
            guard !made.isEmpty else { continue }
            let src = r.pick(made)
            let others = made.filter { $0 != src }
            // 変更先の名前: 乱数 / 他のファイルの名前そのまま / 他や自分の名前の大文字小文字・正規化違い
            var name = randomName(&r)
            switch r.int(6) {
            case 0 where !others.isEmpty: name = r.pick(others)
            case 1 where !others.isEmpty: name = r.pick(others).uppercased()
            case 2: name = src.uppercased()
            case 3: name = src.precomposedStringWithCanonicalMapping
            case 4: name = src.decomposedStringWithCanonicalMapping + (r.chance(0.5) ? "" : r.pick(pieces))
            default: break
            }

            let before = snapshot(dir)
            let srcURL = dir.appendingPathComponent(src)
            let srcContent = before.first(where: { scalarsEqual($0.key, src) })!.value
            let outcome = renameInPlace(srcURL, to: name)
            let after = snapshot(dir)

            var problems: [String] = []
            if before.values.sorted() != after.values.sorted() {
                problems.append("ファイルが消えた/上書きされた")
            }
            let expected: String
            if name == src { expected = "unchanged" }
            else if expectedInvalid(name) { expected = "rejected" }
            else if others.contains(where: { apfsKey($0) == apfsKey(name) }) { expected = "failed" }
            else { expected = "renamed" }

            switch outcome {
            case .renamed(let dst):
                counts["renamed", default: 0] += 1
                // 濁点・アクセントは分解形 (NFD) で保存される (URL を通すため。Finder と同じ)。正規化の違いは同じ名前とみなす
                // 戻り値の URL で中身が読めること (名前の文字列は比べない。先頭の U+FEFF を URL が表示上落とすため)
                if readContent(dst.path) != srcContent { problems.append("戻り値の URL で元の中身が読めない: \(show(dst.path))") }
                if !after.keys.contains(where: { $0 == name }) { problems.append("指定した名前の項目が無い") }
                if after.first(where: { $0.key == name })?.value != srcContent { problems.append("新しい名前で元の中身が読めない") }
                if after.count != before.count { problems.append("ファイル数が変わった") }
            case .unchanged, .rejected, .failed:
                counts["\(outcome)".components(separatedBy: "(")[0], default: 0] += 1
                if before != after { problems.append("変えていないはずなのにフォルダが変わった") }
            }
            var got = "\(outcome)".components(separatedBy: "(")[0]
            // 名前が U+FEFF で始まると URL がそれを落とすため、同じ名前でも unchanged 以外 (変えたが何も変わらない、
            // 分解形にすると長すぎる等) が返ることがある。フォルダが何も変わっていなければ実害なし
            if expected == "unchanged" && before == after { got = "unchanged" }
            if got != expected { problems.append("結果が \(got) (期待は \(expected)): \(outcome)") }

            if !problems.isEmpty {
                failures += 1
                if failures <= Int(env["FUZZ_SHOW"] ?? "10")! {
                    print("FAIL #\(i) (FUZZ_SEED=\(seed))")
                    print("  ファイル: \(made.map(show))")
                    print("  変える:   \(show(src)) → \(show(name))")
                    for p in problems { print("  - \(p)") }
                    print("  後:       \(after.keys.sorted().map(show))")
                }
            }
            try? FileManager.default.removeItem(at: dir)
        }
        try? FileManager.default.removeItem(at: root)
        print("rename fuzz: \(n) 回, 失敗 \(failures), 内訳 \(counts.sorted { $0.key < $1.key })")
        exit(failures == 0 ? 0 : 1)
    }
}
