// ~/Downloads と Dropbox のカメラアップロードをサムネイルで並べ、他アプリへドラッグで渡すための置き場。
// 2つのフォルダは区別せず1つの一覧にまとめる (箱の正規表現もファイル名だけに当てる)。
// Finder の窓状態 (ツールバー/サイドバー非表示) は次に開く Finder 窓へ引き継がれるため、
// 見た目を Finder と切り離す目的で専用アプリにしている。
// - 新しい順 (追加日) に並べ、フォルダの変更を監視して自動更新する
// - ドラッグは file URL を渡す。外へのドラッグは常にコピー (Finder 窓へ落としても移動にならず、Dock のゴミ箱へ落としても消えない)
// - ダブルクリックで既定アプリで開く。Esc / 閉じるボタンでアプリごと隠す
// - 窓の左の列: 上半分は Claude Code などを動かすターミナル (TerminalPane)、下半分は選んだファイルのプレビュー
// - 名前の下にファイルサイズ (Finder と同じ表記)
// - 名前は文字単位で折り返す (サムネイル 3 行・リスト 2 行まで)。それでも入らない長い名前だけ真ん中を … で詰め、
//   ホバーでフルネームを出す
// - タイトルバー右端の「ゴミ箱に入れる」で、選択中のファイルをゴミ箱へ移す (選択が無い時は押せない)
//   以前は一覧の先頭にゴミ箱セルを置いてドラッグで落とす方式だったが、同じ窓内のドロップが安定せず
//   (Esc 取り消しでも消える・ハイライトが一瞬で消える等) 撤去した
// - 英数+E (Karabiner が ⌃⌥⌘F16 を送る) を自前の Carbon ホットキーで受ける。普通の窓なので他の窓の後ろにも回る
//   - 手前にある → 隠す / 後ろにある → 手前に出す (位置はそのまま)
//   - 隠れている → 一番右の画面の右端 (幅は左の列 6 列分・シェルフ 4 列分・自作タスクバーを除いた全高) に置いてから出す
//   以前は Hammerspoon が unhide → 窓の出現をポーリング → setFrame していたが、古い位置に一瞬出てから
//   飛ぶうえに遅かったため、配置してから表示するまでをアプリ内で一度に行う
// - 起動は Hammerspoon が起動時に裏で行う (常駐)。起動直後は窓を出さない
// - 一覧は上下に並ぶ「箱」に分かれる。箱ごとにファイル名の正規表現を指定 (例: "\.xlsx?$"、空欄で全部。大文字小文字は区別しない)
//   - 箱は見え方だけ。同じファイルが複数の箱に出てよい。指定は入力欄からフォーカスが外れた時点で反映
//   - 箱は横幅いっぱい・高さはファイル数なり。見出しの ▸ で閉じると見出しだけになる
//   - タイトルバーの「箱を追加」で追加、見出しの × で削除。「すべて開く / すべて閉じる」もタイトルバーに構成は UserDefaults に保存
// - 箱の上の検索欄でファイル名を絞り込む (打つたびに反映、全部の箱が対象)。× か Esc で消すと元の表示に戻る
//   - 空白区切りは AND。大文字小文字・全角半角は区別しない
//   - 箱ごとにサムネイル / リスト表示を切り替えられる (見出しの右のボタン)
//   - 見出しをクリックで開閉、上下にドラッグで並べ替え (入力欄・ボタン以外の部分)
// - 配色は Mattermost のサイドバー (既定テーマ Denim、背景はより濃く) に寄せている。ライト/ダークに関係なく固定
// - 選択が 1 つの時、Enter かタイトルバーの「名前を変更」で名前を変える (手順は RenameFile.swift の説明)
// ゴミ箱へ移す・名前の変更以外のファイル操作は持たない (Finder に任せる)。

import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing
import Quartz   // QLPreviewView (左下のプレビュー欄)
import WebKit   // ターミナルの画面 (xterm.js)

let home = FileManager.default.homeDirectoryForCurrentUser
let downloadsURL = home.appendingPathComponent("Downloads")
let folderURLs = [downloadsURL, home.appendingPathComponent("Library/CloudStorage/Dropbox/カメラアップロード")]
let thumbSize = CGSize(width: 96, height: 96)
// 自作タスクバー (hammerspoon/taskbar.lua の BAR_H=43) + 窓との隙間 (init.lua の TASKBAR_GAP=8)
let taskbarInset: CGFloat = 43 + 8

// Mattermost Denim テーマのサイドバー色。背景だけ Denim (#1e325c) より濃くしている
let mmSidebar = NSColor(srgbRed: 0x11 / 255.0, green: 0x1a / 255.0, blue: 0x28 / 255.0, alpha: 1)
let mmAccent = NSColor(srgbRed: 0x5d / 255.0, green: 0x89 / 255.0, blue: 0xea / 255.0, alpha: 1)
let mmText = NSColor.white.withAlphaComponent(0.64)   // 見出し・非アクティブ文字
let mmHover = NSColor.white.withAlphaComponent(0.08)
// 箱の見出しの地。Denim 本来のサイドバー色で、背景より一段明るくして箱の切れ目を見失わないようにする
let mmHeader = NSColor(srgbRed: 0x1e / 255.0, green: 0x32 / 255.0, blue: 0x5c / 255.0, alpha: 1)

// 名前の折り返し (文字単位) と、行数制限を超える時の真ん中省略
let thumbNameFont = NSFont.systemFont(ofSize: 11)
let listNameFont = NSFont.systemFont(ofSize: 12)
let thumbNameLines = 3
let listNameLines = 2

func textHeight(_ s: String, _ font: NSFont, _ width: CGFloat) -> CGFloat {
    let para = NSMutableParagraphStyle()
    para.lineBreakMode = .byCharWrapping
    return ceil((s as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin],
                                             attributes: [.font: font, .paragraphStyle: para]).height)
}

func linesHeight(_ font: NSFont, _ lines: Int) -> CGFloat {
    textHeight(Array(repeating: "あ", count: lines).joined(separator: "\n"), font, 1000)
}

// width に lines 行で収まればそのまま。収まらなければ頭と末尾 (拡張子・連番) を残して真ん中を … にする
func fitName(_ name: String, _ font: NSFont, _ width: CGFloat, _ lines: Int) -> String {
    let limit = linesHeight(font, lines)
    if width <= 0 || textHeight(name, font, width) <= limit { return name }
    let chars = Array(name)
    func cut(_ keep: Int) -> String {
        let head = keep / 2
        return String(chars[..<head]) + "…" + String(chars[(chars.count - (keep - head))...])
    }
    var lo = 0, hi = chars.count - 1
    while lo < hi {
        let mid = (lo + hi + 1) / 2
        if textHeight(cut(mid), font, width) <= limit { lo = mid } else { hi = mid - 1 }
    }
    return cut(lo)
}

// 名前ラベルの共通設定。表示幅が決まってから (viewDidLayout) 詰めた文字列を入れる
func setupNameLabel(_ label: NSTextField, _ font: NSFont, _ lines: Int) {
    label.font = font
    label.textColor = NSColor.white.withAlphaComponent(0.9)
    label.lineBreakMode = .byCharWrapping
    label.usesSingleLineMode = false
    label.cell?.wraps = true
    label.maximumNumberOfLines = lines
}

func applyName(_ item: NSCollectionViewItem, _ label: NSTextField, _ name: String, _ lines: Int) {
    // 文字の描画域はラベル幅より左右 2pt ずつ狭い
    let fitted = fitName(name, label.font!, label.bounds.width - 4, lines)
    if label.stringValue != fitted { label.stringValue = fitted }
    item.view.toolTip = fitted == name ? nil : name
}

final class ShelfItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ShelfItem")
    let frameBox = NSBox()   // サムネイルの外枠。縦横比の違う画像でもアイテムの範囲が分かるように
    let thumb = NSImageView()
    let label = NSTextField(labelWithString: "")
    let sizeLabel = NSTextField(labelWithString: "")
    var url: URL?
    var name = "" { didSet { view.needsLayout = true } }

    // セル高: 上余白 4 + 枠 + 2 + 名前 3 行 + サイズ 1 行 + 下余白 4
    static var height: CGFloat { 4 + thumbSize.height + 8 + 2 + linesHeight(thumbNameFont, thumbNameLines) + 14 + 4 }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyName(self, label, name, thumbNameLines)
    }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        // NSBox の custom 型はライト/ダーク切替で色を追従してくれる
        frameBox.boxType = .custom
        frameBox.borderColor = NSColor.white.withAlphaComponent(0.16)
        frameBox.fillColor = NSColor.white.withAlphaComponent(0.04)
        frameBox.borderWidth = 1
        frameBox.cornerRadius = 6
        frameBox.contentViewMargins = .zero
        frameBox.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        setupNameLabel(label, thumbNameFont, thumbNameLines)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        sizeLabel.font = .systemFont(ofSize: 10)
        sizeLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        sizeLabel.alignment = .center
        sizeLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(frameBox)
        v.addSubview(thumb)
        v.addSubview(label)
        v.addSubview(sizeLabel)
        NSLayoutConstraint.activate([
            frameBox.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            frameBox.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            frameBox.widthAnchor.constraint(equalToConstant: thumbSize.width + 8),
            frameBox.heightAnchor.constraint(equalToConstant: thumbSize.height + 8),
            thumb.centerXAnchor.constraint(equalTo: frameBox.centerXAnchor),
            thumb.centerYAnchor.constraint(equalTo: frameBox.centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: thumbSize.width),
            thumb.heightAnchor.constraint(equalToConstant: thumbSize.height),
            // 名前は上詰め、サイズはセル下端に揃える (行数が違ってもサイズの位置が揃う)
            label.topAnchor.constraint(equalTo: frameBox.bottomAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            label.bottomAnchor.constraint(equalTo: sizeLabel.topAnchor),
            sizeLabel.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
            sizeLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            sizeLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
        ])
        view = v
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? mmAccent.withAlphaComponent(0.45).cgColor : nil }
    }
}

// 箱の設定。id は選択の持ち越しと見出しからの操作を、並びが変わっても取り違えないため
struct Box: Codable {
    var id = UUID()
    var filter: String
    var open = true
    var list = false   // true でリスト表示
    var byName = false     // 並び: true で名前順、false で追加日順
    var ascending = false  // true で昇順 (名前は A→Z、日付は古い順)

    // ファイル名に対する正規表現 (部分一致)。書き方が誤っていれば nil で、その箱には何も出さない
    var regex: NSRegularExpression? { try? NSRegularExpression(pattern: filter, options: [.caseInsensitive]) }

    // 受け取る urls は新しい順。それを箱の並びに並べ直して返す
    func filtered(_ urls: [URL]) -> [URL] {
        guard let regex else { return [] }
        var hits = urls.filter {
            let name = $0.lastPathComponent
            return regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
        if byName {
            // Finder と同じ比較 (数字は数として、大文字小文字・全角半角は区別しない)
            hits.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if !ascending { hits.reverse() }
        } else if ascending {
            hits.reverse()
        }
        return hits
    }
}

// リスト表示の 1 行: アイコン・名前・サイズ
final class ShelfListItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ShelfListItem")
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let sizeLabel = NSTextField(labelWithString: "")
    var url: URL?
    var name = "" { didSet { view.needsLayout = true } }
    static let sizeFont = NSFont.systemFont(ofSize: 11)

    // 行の高さ: 名前が 1 行なら 26、折り返すならその分だけ高くする (最大 2 行)
    static func height(name: String, size: String, rowWidth: CGFloat) -> CGFloat {
        let sizeW = ceil((size as NSString).size(withAttributes: [.font: sizeFont]).width) + 4
        let labelW = rowWidth - 8 - 18 - 8 - 8 - sizeW - 8 - 4
        let h = min(textHeight(name, listNameFont, labelW), linesHeight(listNameFont, listNameLines))
        return max(26, h + 10)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyName(self, label, name, listNameLines)
    }

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        icon.imageScaling = .scaleProportionallyUpOrDown
        setupNameLabel(label, listNameFont, listNameLines)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sizeLabel.font = Self.sizeFont
        sizeLabel.textColor = NSColor.white.withAlphaComponent(0.48)
        sizeLabel.alignment = .right
        sizeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        for x in [icon, label, sizeLabel] as [NSView] {
            x.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(x)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.topAnchor.constraint(equalTo: v.topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -3),
            sizeLabel.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            sizeLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            sizeLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        view = v
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? mmAccent.withAlphaComponent(0.45).cgColor : nil }
    }
}

// 箱の見出し (Mattermost のサイドバーのカテゴリ見出し風): ▾/▸・正規表現の入力欄 | 件数 … 名前/日付・表示切替 … ×
// (箱のファイルを全部ゴミ箱へ入れるボタンは、押し間違いが危険すぎるので外した)
// 入力欄とボタン以外の部分は、クリックで開閉・上下ドラッグで並べ替え
final class BoxHeader: NSView, NSCollectionViewElement, NSTextFieldDelegate {
    static let id = NSUserInterfaceItemIdentifier("BoxHeader")
    let toggle = NSButton()
    let field = NSTextField()
    let divider = NSView()   // 入力欄と、掴める空きとの境目の縦線
    let bottomLine = NSView()   // 見出しの下線 (上にも引くと閉じた箱が並ぶ所で二重になる)
    let count = NSTextField(labelWithString: "")
    let remove = NSButton()
    let mode = NSButton()   // サムネイル / リスト切替
    let sortName = NSButton()   // 名前順。並び中に押すと昇順/降順の切替
    let sortDate = NSButton()   // 追加日順。同上
    var boxID: UUID?
    weak var owner: AppDelegate?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = mmHeader.cgColor
        let symbol = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        toggle.isBordered = false
        toggle.contentTintColor = mmText
        toggle.symbolConfiguration = symbol
        toggle.target = self
        toggle.action = #selector(toggleTapped)
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12, weight: .semibold)
        field.textColor = mmText
        field.placeholderAttributedString = NSAttributedString(string: "すべて", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.32), .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        field.toolTip = "表示するファイル名の正規表現 (例: \\.xlsx?$)。空欄で全部。書き方が誤っていると赤字になり何も出ない"
        field.delegate = self
        for line in [divider, bottomLine] {
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        }
        count.font = .systemFont(ofSize: 11)
        count.textColor = NSColor.white.withAlphaComponent(0.4)
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "箱を削除")
        remove.symbolConfiguration = symbol
        remove.contentTintColor = mmText
        remove.isBordered = false
        remove.toolTip = "この箱を削除 (ファイルは消えない)"
        remove.target = self
        remove.action = #selector(removeTapped)
        mode.symbolConfiguration = symbol
        mode.contentTintColor = mmText
        mode.isBordered = false
        mode.target = self
        mode.action = #selector(modeTapped)
        for (b, action) in [(sortName, #selector(sortNameTapped)), (sortDate, #selector(sortDateTapped))] {
            b.isBordered = false
            b.target = self
            b.action = action
        }
        sortName.toolTip = "名前順にする (名前順の時は昇順/降順の切替)"
        sortDate.toolTip = "追加日順にする (日付順の時は新しい順/古い順の切替)"
        for v in [bottomLine, toggle, field, divider, sortName, sortDate, count, mode, remove] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([bottomLine.leadingAnchor.constraint(equalTo: leadingAnchor),
                                     bottomLine.trailingAnchor.constraint(equalTo: trailingAnchor),
                                     bottomLine.heightAnchor.constraint(equalToConstant: 1)])
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 4),
            divider.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 4),
            count.leadingAnchor.constraint(equalTo: divider.trailingAnchor, constant: 8),
            divider.centerYAnchor.constraint(equalTo: centerYAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 14),
            bottomLine.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 固定幅にして、右側の空きを掴める場所として残す (編集可能な欄は文字幅を持たないので広がってしまう)
            field.widthAnchor.constraint(equalToConstant: 120),
            sortName.trailingAnchor.constraint(equalTo: sortDate.leadingAnchor, constant: -8),
            sortName.centerYAnchor.constraint(equalTo: centerYAnchor),
            sortDate.trailingAnchor.constraint(equalTo: mode.leadingAnchor, constant: -10),
            sortDate.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 箱を消す × は間を空けて右端に寄せ、表示の操作と押し間違えないようにする
            mode.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -22),
            mode.centerYAnchor.constraint(equalTo: centerYAnchor),
            mode.widthAnchor.constraint(equalToConstant: 18),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 16),
        ])
        // 右のボタンは押せる範囲を見出しの高さいっぱいにする (絵の大きさだけだと、少し上下に外れると見出しの開閉になる)
        for b in [sortName, sortDate, mode, remove] { b.heightAnchor.constraint(equalTo: heightAnchor).isActive = true }
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ box: Box, fileCount: Int) {
        boxID = box.id
        if field.currentEditor() == nil { field.stringValue = box.filter }
        field.textColor = box.regex == nil ? .systemRed : mmText
        toggle.image = NSImage(systemSymbolName: box.open ? "chevron.down" : "chevron.right",
                               accessibilityDescription: box.open ? "閉じる" : "開く")
        count.stringValue = "\(fileCount)"
        // 押すと切り替わる先の表示を絵にする
        mode.image = NSImage(systemSymbolName: box.list ? "square.grid.2x2" : "list.bullet",
                             accessibilityDescription: box.list ? "サムネイル表示にする" : "リスト表示にする")
        mode.toolTip = box.list ? "サムネイル表示にする" : "リスト表示にする"
        // 今の並びの方だけ明るくして矢印を付ける
        func title(_ b: NSButton, _ text: String, active: Bool) {
            let arrow = active ? (box.ascending ? " ↑" : " ↓") : ""
            b.attributedTitle = NSAttributedString(string: text + arrow, attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: active ? .semibold : .regular),
                .foregroundColor: active ? mmText : NSColor.white.withAlphaComponent(0.32)])
        }
        title(sortName, "名前", active: box.byName)
        title(sortDate, "日付", active: !box.byName)
    }

    // 全体の作り直しで別の箱用に使い回される時だけ、前の箱のホバー表示を消す
    override func prepareForReuse() {
        super.prepareForReuse()
        setHover(false)
    }

    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
    // 入力欄とボタンの間の空き (= 掴んで並べ替える所) では手のひらのカーソルにする
    override func resetCursorRects() {
        addCursorRect(NSRect(x: divider.frame.maxX, y: 0, width: max(0, sortName.frame.minX - divider.frame.maxX),
                             height: bounds.height), cursor: .openHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    func setHover(_ on: Bool) {
        layer?.backgroundColor = (on ? mmHeader.blended(withFraction: 0.08, of: .white)! : mmHeader).cgColor
    }

    // 並び替えボタンから右 (ボタンの並ぶ所) は、ボタンの隙間を押しても開閉・並べ替えにしない
    override func mouseDown(with event: NSEvent) {
        if convert(event.locationInWindow, from: nil).x >= sortName.frame.minX { return }
        if let boxID { owner?.trackHeaderDrag(boxID, header: self, down: event) }
    }

    @objc func toggleTapped() { if let boxID { owner?.toggleBox(boxID) } }
    @objc func modeTapped() { if let boxID { owner?.toggleListMode(boxID) } }
    @objc func sortNameTapped() { if let boxID { owner?.setSort(boxID, byName: true) } }
    @objc func sortDateTapped() { if let boxID { owner?.setSort(boxID, byName: false) } }
    @objc func removeTapped() { if let boxID { owner?.removeBox(boxID) } }
    // Enter・Tab・別の場所のクリックのどれでも来る (確定ボタンは置かない)
    func controlTextDidEndEditing(_ obj: Notification) {
        if let boxID { owner?.setFilter(boxID, field.stringValue, from: field) }
    }
}

// - アイテム上: ダブルクリックで開く。1回目のクリックは通常どおり選択・ドラッグに回す
// - アイテム外の余白: 標準どおり (クリックで選択解除・ドラッグで範囲選択)
final class ShelfCollectionView: NSCollectionView {
    var onOpen: ((IndexPath) -> Void)?
    var onReturn: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) { onReturn?(); return }
        super.keyDown(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)   // 入力欄の編集をここで終わらせる (= 正規表現・検索語の確定)
        if event.clickCount == 2, let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            onOpen?(ip)
            return
        }
        super.mouseDown(with: event)
    }
}

// 通常の窓 (信号機ボタンは Finder と同じ 3 つ)。utility パネルだとボタンが小さい別物になるため使わない
final class ShelfWindow: NSWindow {
    // Esc で隠す。ただしターミナルで打った Esc は中のプログラム (Claude Code の中断など) のものなので隠さない
    override func cancelOperation(_ sender: Any?) {
        if firstResponder is TerminalWebView { return }
        (NSApp.delegate as? AppDelegate)?.hide()
    }
}

// 左の列の幅。シェルフのサムネイル (枠 96+16) 6 個分
let leftWidth = 6 * (thumbSize.width + 16) + 5 * 4 + 12

// MARK: - ターミナル (左の列の上半分)
// Claude Code を動かすための端末。画面は WKWebView の中の xterm.js (terminal/。VS Code の端末と同じもの。
// Windows 側の Tsuzuri の AI の欄と同じ作り)。中のシェルとは疑似端末 (forkpty) でつなぐ。
// - ~/Downloads でログインシェル (zsh -l -i) を起動し、すぐに claude を動かす。PATH 等は .zprofile / .zshrc のとおり
//   claude を終えると普通のシェルになる (exec で同じ場所のログインシェルに替わる)
// - claude には Tsuzuri と同じく、起動時に「ここがどこか」の指示 (--append-system-prompt-file) を、話しかけるたびに
//   「今の状態」(プレビュー中のファイルのパス) をフック (UserPromptSubmit) で渡す。ファイルは ClaudeContext を参照
// - 窓を隠しても動き続ける。シェルが終わったら、次にキーを押した時に起動し直す (また claude から)
// - キー: Karabiner で物理 Ctrl が Cmd になっているので、Windows Terminal と同じ感覚になるよう Cmd を読み替える
//   - Cmd+C: 選んでいればコピー、選んでいなければ中断 (^C)。Cmd+V: 貼り付け (画像だけなら ^V を送り Claude Code が自分で読む)
//   - ほかの Cmd+英字は Ctrl+英字として送る。Cmd+Backspace は直前の 1 単語を消す (^W)
//   - Shift+Enter は改行 (ESC CR。Claude Code の /terminal-setup が VS Code に設定するのと同じ)
// - シェルフや Finder からファイルを落とすと、そのパスを貼り付ける (Claude Code に画像や資料を渡せる)
// - 端末の中のリンクは既定のブラウザで開く。ページ自体はよそへ移動させない
// claude に渡すファイル。~/Library/Application Support/local.zero-reach.downloads-shelf/ に置く。
// 指示と設定 (フック) は起動のたびに書き直し、今の状態はプレビューが変わるたびに書き直す (フックは cat するだけ)
enum ClaudeContext {
    static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("local.zero-reach.downloads-shelf")
    static let instructions = dir.appendingPathComponent("instructions.md")
    static let settings = dir.appendingPathComponent("settings.json")
    static let state = dir.appendingPathComponent("state.md")

    // シェルの引用符で囲む
    static func quote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    // claude の起動コマンド (シェルの -c に渡す)
    static var command: String {
        "claude --settings \(quote(settings.path)) --append-system-prompt-file \(quote(instructions.path))"
    }

    static func prepare() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let folders = folderURLs.map { "  - " + $0.path }.joined(separator: "\n")
        let text = """
            # DownloadsShelf のターミナル
            あなた (Claude Code) は、利用者が自作した Mac アプリ DownloadsShelf の窓の左上にあるターミナルで動いている。
            - DownloadsShelf は、次のフォルダのファイルをサムネイルで並べる置き場 (2つのフォルダは区別せず1つの一覧)。作業フォルダは ~/Downloads
            \(folders)
            - 窓の左下はプレビュー欄。利用者がシェルフで選んだファイル 1 つの中身を表示している
            - 話しかけられるたびに「DownloadsShelf の今の状態」が添えられ、プレビュー中のファイルのフルパスが書いてある
            - 利用者が「これ」「このファイル」「プレビューの」などと言ったら、そのファイルのこと。話がそのファイルに関係なければ触れなくてよい
            - ファイルをこのターミナルに落とすと、そのパスが貼り付けられる
            - ファイルを消す・移す・上書きする前は、利用者に確かめる (ダウンロードしたものは原本しか無いことが多い)

            """
        try? text.write(to: instructions, atomically: true, encoding: .utf8)
        let hook: [String: Any] = ["hooks": ["UserPromptSubmit": [["hooks": [["type": "command", "command": "cat " + quote(state.path)]]]]]]
        try? JSONSerialization.data(withJSONObject: hook, options: [.prettyPrinted, .withoutEscapingSlashes]).write(to: settings, options: .atomic)
    }

    static func write(preview url: URL?) {
        var text = "# DownloadsShelf の今の状態 (話しかけた時点)\n"
        if let url {
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            let size = v?.isDirectory == true ? "フォルダ"
                : v?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "?"
            text += "プレビュー中のファイル: \(url.path) (\(size))\n"
        } else {
            text += "プレビュー中のファイルは無い (何も選んでいないか、複数選んでいる)\n"
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? text.write(to: state, atomically: true, encoding: .utf8)
    }
}

final class TerminalWebView: WKWebView {
    weak var pane: TerminalPane?

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard window?.firstResponder === self, let pane,
              e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command
        else { return super.performKeyEquivalent(with: e) }
        if e.keyCode == UInt16(kVK_Delete) { pane.send("\u{17}"); return true }
        guard let ch = e.charactersIgnoringModifiers?.lowercased(), ch.count == 1,
              let a = ch.unicodeScalars.first, a.value >= 0x61, a.value <= 0x7a
        else { return super.performKeyEquivalent(with: e) }
        switch ch {
        case "c": pane.copyOrInterrupt()
        case "v": pane.paste()
        default: pane.send(String(UnicodeScalar(a.value - 0x60)!))
        }
        return true
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { fileURLs(info).isEmpty ? [] : .copy }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation { fileURLs(info).isEmpty ? [] : .copy }
    override func prepareForDragOperation(_ info: NSDraggingInfo) -> Bool { !fileURLs(info).isEmpty }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        let urls = fileURLs(info)
        guard !urls.isEmpty else { return false }
        // シェルの引用符で囲む ('...'。中の ' は '\'' に)
        pane?.pasteText(urls.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ") + " ")
        window?.makeFirstResponder(self)
        return true
    }
    func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

final class TerminalPane: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let view: TerminalWebView
    var fd: Int32 = -1
    var pid: pid_t = 0
    var reader: DispatchSourceRead?
    var pending = Data()      // xterm へまだ渡していない出力
    var feeding = false       // xterm へ渡している最中 (その間に届いた分はまとめて次に渡す)
    var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)

    override init() {
        let config = WKWebViewConfiguration()
        view = TerminalWebView(frame: .zero, configuration: config)
        super.init()
        view.pane = self
        view.configuration.userContentController.add(self, name: "host")
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")   // 読み込み中に白く光らない
        if let page = Bundle.main.url(forResource: "terminal", withExtension: "html", subdirectory: "terminal") {
            view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
    }

    // ページの外へは移動しない (リンクは linkHandler 経由で既定のブラウザへ)
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.isFileURL == true && action.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }

    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let m = message.body as? [String: Any], let type = m["type"] as? String else { return }
        switch type {
        case "ready", "resize":
            if let c = m["cols"] as? Int, let r = m["rows"] as? Int {
                size.ws_col = UInt16(c)
                size.ws_row = UInt16(r)
                if fd >= 0 { _ = ioctl(fd, UInt(0x80087467), &size) }   // TIOCSWINSZ
            }
            if type == "ready" && fd < 0 { start() }
        case "input":
            if let d = m["data"] as? String { send(d) }
        case "copy":
            if let t = m["text"] as? String, !t.isEmpty { copy(t) }
        case "paste":
            paste()
        case "link":
            if let s = m["url"] as? String, let u = URL(string: s), ["http", "https"].contains(u.scheme ?? "") {
                NSWorkspace.shared.open(u)
            }
        default: break
        }
    }

    func start() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        ClaudeContext.prepare()
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "ja_JP.UTF-8" }   // open で起動したアプリには LANG が無く、日本語が化ける
        // fork 後の子では Swift の確保をしないよう、渡す文字列は先に C の文字列にしておく
        // 先頭の - でログインシェル。-i で .zshrc も読む (claude の PATH や別名が効く)
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("-" + (shell as NSString).lastPathComponent), strdup("-i"), strdup("-c"),
                                                    strdup(ClaudeContext.command + "; exec \"$SHELL\" -l"), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let path = strdup(shell)!, dir = strdup(downloadsURL.path)!
        defer { (argv + envp).forEach { free($0) }; free(path); free(dir) }
        var master: Int32 = -1
        let child = forkpty(&master, nil, nil, &size)
        if child == 0 {
            chdir(dir)
            execve(path, argv, envp)
            _exit(127)
        }
        guard child > 0 else { return }
        pid = child
        fd = master
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in self?.readOutput() }
        src.resume()
        reader = src
    }

    func readOutput() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n > 0 { pending.append(contentsOf: buf[0..<n]); continue }
            if n < 0 && errno == EAGAIN { break }
            ended()   // 0 か EIO: シェルが終わった
            break
        }
        feed()
    }

    func ended() {
        reader?.cancel()
        reader = nil
        close(fd)
        fd = -1
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        pending.append(contentsOf: Array("\r\n[シェルが終了しました。キーを押すと起動し直します]\r\n".utf8))
    }

    // 出力は base64 で渡す (xterm がバイト列として受け、UTF-8 の文字の途中で切れても正しくつなぐ)
    func feed() {
        guard !feeding, !pending.isEmpty else { return }
        feeding = true
        let chunk = pending.base64EncodedString()
        pending.removeAll()
        view.evaluateJavaScript("feed('\(chunk)')") { [weak self] _, _ in
            self?.feeding = false
            self?.feed()
        }
    }

    func send(_ s: String) {
        guard fd >= 0 else { start(); return }   // シェルが終わっていたら、キーを押した時に起動し直す
        let bytes = Array(s.utf8)
        var off = 0
        while off < bytes.count {
            let n = bytes[off...].withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { off += n } else if errno != EAGAIN { break }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyOrInterrupt() {
        view.evaluateJavaScript("takeSelection()") { [weak self] r, _ in
            if let t = r as? String, !t.isEmpty { self?.copy(t) } else { self?.send("\u{03}") }
        }
    }

    func paste() {
        let pb = NSPasteboard.general
        if let t = pb.string(forType: .string), !t.isEmpty { pasteText(t) }
        else if pb.canReadObject(forClasses: [NSImage.self], options: nil) { send("\u{16}") }   // 画像は Claude Code が ^V で自分で読む
    }

    // xterm の貼り付けを通す (中のプログラムが求めていれば貼り付けの印で囲む)
    func pasteText(_ t: String) {
        view.evaluateJavaScript("pasteB64('\(Data(t.utf8).base64EncodedString())')")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSWindowDelegate, NSTextFieldDelegate {
    var window: ShelfWindow!
    var collection: ShelfCollectionView!
    var scroll: NSScrollView!
    var boxes: [Box] = []
    // 表示中の内容。boxes を書き換えてから reload() するまでの間も、collection view はこちらだけを見る
    var shown: [(box: Box, files: [URL])] = []
    var plusButton: NSButton!
    var files: [URL] = []   // フォルダの中身 (新しい順)。箱と検索での振り分け前
    let searchField = NSTextField()
    var clearButton: NSButton!
    var trashButton: NSButton!
    var renameButton: NSButton!
    var selectAfterReload: URL?   // 名前を変えたファイル。次の再読込で選択し直す
    var sizes: [URL: String] = [:]
    var thumbs: [URL: NSImage] = [:]   // キーは path+更新日時を含めたい所だが、上書きダウンロードは稀なので URL で十分
    var watchers: [DispatchSourceFileSystemObject] = []
    var reloadPending = false
    let terminal = TerminalPane()
    let preview = QLPreviewView(frame: .zero, style: .normal)!   // 選択が 1 つの時、その中身を出す

    func applicationDidFinishLaunching(_ note: Notification) {
        ClaudeContext.write(preview: nil)   // 前回の終了時の状態を残さない
        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 4, left: 6, bottom: 10, right: 6)
        layout.headerReferenceSize = NSSize(width: 0, height: 30)   // 縦スクロールでは幅は無視され横幅いっぱい

        collection = ShelfCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.register(ShelfItem.self, forItemWithIdentifier: ShelfItem.id)
        collection.register(ShelfListItem.self, forItemWithIdentifier: ShelfListItem.id)
        collection.register(BoxHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: BoxHeader.id)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)   // 移動・削除は許さない
        collection.setDraggingSourceOperationMask(.copy, forLocal: true)    // ターミナルへはパスを渡す (コピー扱い)
        // 開くのはクリックしたセルが表示しているファイル (再読込で並びがずれても取り違えない)
        collection.onReturn = { [weak self] in self?.renameSelected() }
        collection.onOpen = { [weak self] ip in
            let item = self?.collection.item(at: ip)
            guard let url = (item as? ShelfItem)?.url ?? (item as? ShelfListItem)?.url else { return }
            NSWorkspace.shared.open(url)
        }

        scroll = NSScrollView()
        scroll.automaticallyAdjustsContentInsets = false   // 下余白は keepHeaderInPlace が自分で足す
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        window = ShelfWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        window.title = FileManager.default.displayName(atPath: downloadsURL.path)   // 日本語環境では「ダウンロード」
        window.backgroundColor = mmSidebar
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden   // タイトルバーはボタンで埋まるので出さない (Mission Control 等での名前としては残る)
        window.appearance = NSAppearance(named: .darkAqua)   // 標準部品 (タイトル・スクロールバー等) を紺背景に合う白系に
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        let searchBar = makeSearchBar()
        let content = NSView()
        let pane = terminal.view
        func line() -> NSView {
            let v = NSView()
            v.wantsLayer = true
            v.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
            return v
        }
        let paneLine = line()      // 左の列と一覧の境目
        let previewLine = line()   // ターミナルとプレビューの境目
        for v in [searchBar, pane, previewLine, preview, paneLine, scroll!] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: content.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 36),
            pane.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            pane.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pane.widthAnchor.constraint(equalToConstant: leftWidth),
            pane.heightAnchor.constraint(equalTo: preview.heightAnchor),   // 上下半分ずつ
            previewLine.topAnchor.constraint(equalTo: pane.bottomAnchor),
            previewLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            previewLine.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            previewLine.heightAnchor.constraint(equalToConstant: 1),
            preview.topAnchor.constraint(equalTo: previewLine.bottomAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            paneLine.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            paneLine.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            paneLine.leadingAnchor.constraint(equalTo: pane.trailingAnchor),
            paneLine.widthAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: paneLine.trailingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        addTitlebarButtons()

        loadBoxes()
        reload()
        startWatching()
        registerHotKey()
    }

    // Dock アイコンが無い (LSUIElement) ので、起動中に Finder 等から開き直されたら窓を出す
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        show()
        return false
    }

    // MARK: - 出し入れ

    func toggle() {
        let onScreen = window.isVisible && !window.isMiniaturized
        if onScreen && NSApp.isActive && window.isKeyWindow {
            hide()
        } else if onScreen {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else {
            show()
        }
    }

    // 隠れたまま位置を決めてから表示する (古い位置に一瞬出ない)
    func show() {
        scroll.contentInsets.bottom = 0   // keepHeaderInPlace が足した余白を戻す
        let screen = NSScreen.screens.max { $0.frame.maxX < $1.frame.maxX }   // 一番右の画面
        if let vis = screen?.visibleFrame {   // visibleFrame で右配置 Dock とメニューバーを避ける
            // 左の列 + 境目 1px + シェルフ 4 列 (枠 96+8 と間 4・左右の sectionInset)。スクロールバーが幅を取る設定ならその分も足す
            let shelf = 4 * (thumbSize.width + 8) + 3 * 4 + 12
                + NSScroller.scrollerWidth(for: .regular, scrollerStyle: NSScroller.preferredScrollerStyle)
            let w = min(vis.width, leftWidth + 1 + shelf)
            window.setFrame(NSRect(x: vis.maxX - w, y: vis.minY + taskbarInset, width: w, height: vis.height - taskbarInset),
                            display: false)
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // ⌃⌥⌘F16。Carbon ホットキーは Parallels (Coherence) が前面でも発火する
    func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            MainActor.assumeIsolated { (NSApp.delegate as? AppDelegate)?.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5A52_5348), id: 1)   // 'ZRSH'
        RegisterEventHotKey(UInt32(kVK_F16), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // 前のアプリにフォーカスが戻る。編集中の正規表現は隠す前に確定させる
    func hide() {
        endEditing()
        NSApp.hide(nil)
    }

    // 入力欄の編集を終わらせる (controlTextDidEndEditing → setFilter が走る)。
    // 見出しを作り直す操作の前に呼ぶ。ボタンはフォーカスを取らないので、押しても編集は終わらない
    func endEditing() {
        if isEditing { window.makeFirstResponder(collection) }
    }

    // 箱の見出しの入力欄を編集中か (検索欄は含めない。検索中も表示は作り直す)
    var isEditing: Bool {
        guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return false }
        return (editor.delegate as? NSView)?.superview is BoxHeader
    }

    // MARK: - 検索欄

    func makeSearchBar() -> NSView {
        let bar = NSView()
        let label = NSTextField(labelWithString: "検索")
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor.white.withAlphaComponent(0.48)
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.font = .systemFont(ofSize: 13)
        searchField.textColor = NSColor.white.withAlphaComponent(0.9)
        searchField.placeholderAttributedString = NSAttributedString(string: "ファイル名で絞り込み", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.32), .font: NSFont.systemFont(ofSize: 13)])
        searchField.cell?.isScrollable = true
        searchField.delegate = self
        clearButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "検索を消す")!,
                               target: self, action: #selector(clearSearch))
        clearButton.isBordered = false
        clearButton.contentTintColor = mmText
        clearButton.isHidden = true
        let line = NSBox()   // 下辺の区切り線
        line.boxType = .custom
        line.borderWidth = 0
        line.fillColor = NSColor.white.withAlphaComponent(0.1)
        for v in [label, searchField, clearButton!, line] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }
        label.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            searchField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            searchField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: clearButton.leadingAnchor, constant: -8),
            clearButton.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            clearButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            clearButton.widthAnchor.constraint(equalToConstant: 20),
            line.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return bar
    }

    var searchWords: [String] {
        searchField.stringValue.split { $0.isWhitespace }.map(String.init)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSTextField === searchField else { return }
        clearButton.isHidden = searchField.stringValue.isEmpty
        rebuild()
    }

    // 検索欄で Esc: 文字があれば消す、空なら通常どおり隠す
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard control === searchField, sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if searchField.stringValue.isEmpty { hide() } else { clearSearch() }
        return true
    }

    @objc func clearSearch() {
        searchField.stringValue = ""
        clearButton.isHidden = true
        rebuild()
    }

    // MARK: - 箱

    func loadBoxes() {
        if let data = UserDefaults.standard.data(forKey: "boxes"),
           let saved = try? JSONDecoder().decode([Box].self, from: data) {
            boxes = saved
        } else {
            boxes = [Box(filter: "")]
        }
    }

    func saveBoxes() {
        if let data = try? JSONEncoder().encode(boxes) { UserDefaults.standard.set(data, forKey: "boxes") }
    }

    func setFilter(_ id: UUID, _ filter: String, from field: NSTextField) {
        guard let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        boxes[i].filter = filter
        saveBoxes()
        // 編集終了の通知中に見出しを作り直さない。
        // Enter で確定しても入力欄はフォーカスを持ったまま (全選択状態) なので、その欄からは外してから反映する。
        // 別の箱の入力欄へ移った場合はその編集を邪魔せず、そちらの編集終了時にまとめて反映する
        DispatchQueue.main.async {
            if (self.window.firstResponder as? NSTextView)?.delegate === field { self.window.makeFirstResponder(self.collection) }
            self.reload()
        }
    }

    func toggleBox(_ id: UUID) {
        endEditing()
        guard let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        keepHeaderInPlace(id) {
            boxes[i].open.toggle()
            saveBoxes()
            refreshBox(i)
        }
    }

    func toggleListMode(_ id: UUID) {
        endEditing()
        guard let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        keepHeaderInPlace(id) {
            boxes[i].list.toggle()
            saveBoxes()
            refreshBox(i)
        }
    }

    // 今の並びのボタンなら昇順/降順を入れ替え、もう一方なら並びを切り替える (名前は昇順、日付は新しい順から)
    func setSort(_ id: UUID, byName: Bool) {
        endEditing()
        guard let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        keepHeaderInPlace(id) {
            if boxes[i].byName == byName {
                boxes[i].ascending.toggle()
            } else {
                boxes[i].byName = byName
                boxes[i].ascending = byName
            }
            saveBoxes()
            refreshBox(i)
        }
    }

    // 見出しからの操作 (開閉・表示切替・並べ替え・削除) では一覧を全部作り直さない。
    // 全部作り直すと見出しの部品が別の箱用に使い回され、直前に押した部品へ届く後続のイベント
    // (ダブルクリックの 2 回目など) が別の箱に当たる。中身のセルだけ入れ替え、見出しは同じ部品をその場で書き換える
    func refreshBox(_ s: Int) {
        if isEditing { return }   // 入力中は setFilter → reload で全体を作り直す
        let section = { (n: Int) in Set((0..<n).map { IndexPath(item: $0, section: s) }) }
        let selected = Set(collection.selectionIndexPaths.filter { $0.section == s }.compactMap { url(at: $0) })
        let oldCount = collection.numberOfItems(inSection: s)
        shown[s] = (boxes[s], boxes[s].filtered(searchHits()))
        let newCount = collectionView(collection, numberOfItemsInSection: s)
        collection.performBatchUpdates({
            collection.deleteItems(at: section(oldCount))
            collection.insertItems(at: section(newCount))
        })
        let keep = shown[s].box.open ? shown[s].files.indices.filter { selected.contains(shown[s].files[$0]) } : []
        collection.selectItems(at: Set(keep.map { IndexPath(item: $0, section: s) }), scrollPosition: [])
        (collection.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader,
                                      at: IndexPath(item: 0, section: s)) as? BoxHeader)?
            .configure(shown[s].box, fileCount: shown[s].files.count)
        updateTrashButton()
    }

    // 見出しから箱を開閉・切替した時、その見出しを画面上の同じ位置に留める。
    // 下の方までスクロールした状態で箱が縮むとスクロール位置が押し戻されて一覧が下へずれ、
    // マウスの下に別の箱の見出しが来て、続けてのクリックが別の箱に当たってしまうため。
    // 中身が足りなくて留められない時は下に余白を足す (余白は次に窓を出し直す時に消す)
    func keepHeaderInPlace(_ id: UUID, _ change: () -> Void) {
        let clip = scroll.contentView
        func headerFrame() -> NSRect? {
            guard let s = shown.firstIndex(where: { $0.box.id == id }) else { return nil }
            return collection.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader,
                                                                      at: IndexPath(item: 0, section: s))?.frame
        }
        let before = headerFrame().map { $0.minY - clip.bounds.minY }
        change()
        collection.layoutSubtreeIfNeeded()
        guard let before, let after = headerFrame() else { return }
        let origin = max(0, after.minY - before)
        let contentH = collection.collectionViewLayout?.collectionViewContentSize.height ?? 0
        scroll.contentInsets.bottom = max(0, origin + clip.bounds.height - contentH)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: origin))
        scroll.reflectScrolledClipView(clip)
    }

    func removeBox(_ id: UUID) {
        endEditing()
        guard !isEditing, let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        boxes.remove(at: i)
        saveBoxes()
        shown.remove(at: i)
        collection.performBatchUpdates({ collection.deleteSections(IndexSet(integer: i)) })
        updateTrashButton()
    }

    // 見出しの mouseDown から。動かさずに離せば開閉、上下に動かせば並べ替え。
    // 横には動かさない (見出しの写しを縦にだけ追従させ、挿入位置に線を引く)
    func trackHeaderDrag(_ id: UUID, header: BoxHeader, down: NSEvent) {
        endEditing()
        guard let from = shown.firstIndex(where: { $0.box.id == id }) else { return }
        let kind = NSCollectionView.elementKindSectionHeader
        func headerFrame(_ s: Int) -> NSRect? {
            collection.layoutAttributesForSupplementaryElement(ofKind: kind, at: IndexPath(item: 0, section: s))?.frame
        }
        let start = collection.convert(down.locationInWindow, from: nil)
        let origin = header.frame
        var ghost: NSImageView?
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = mmAccent.cgColor
        var target = from
        while let ev = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), ev.type == .leftMouseDragged {
            collection.autoscroll(with: ev)
            let p = collection.convert(ev.locationInWindow, from: nil)
            if ghost == nil {
                guard abs(p.y - start.y) > 3 else { continue }
                header.setHover(false)
                guard let rep = header.bitmapImageRepForCachingDisplay(in: header.bounds) else { return }
                header.cacheDisplay(in: header.bounds, to: rep)
                let img = NSImage(size: header.bounds.size)
                img.addRepresentation(rep)
                let g = NSImageView(frame: origin)
                g.image = img
                g.wantsLayer = true
                g.layer?.backgroundColor = mmSidebar.blended(withFraction: 0.12, of: .white)?.cgColor
                g.layer?.cornerRadius = 4
                g.layer?.borderWidth = 1
                g.layer?.borderColor = mmAccent.cgColor
                collection.addSubview(g)
                collection.addSubview(line)
                header.alphaValue = 0.3
                ghost = g
            }
            ghost?.frame.origin.y = origin.minY + (p.y - start.y)   // collection view は上原点 (flipped)
            // 挿入位置 = カーソルより上にある見出しの数
            target = (0..<shown.count).filter { (headerFrame($0)?.midY ?? .infinity) < p.y }.count
            let y = target < shown.count ? (headerFrame(target)?.minY ?? 0) : collection.bounds.maxY - 2
            line.frame = NSRect(x: 6, y: max(0, y - 1), width: collection.bounds.width - 12, height: 2)
        }
        header.alphaValue = 1
        guard let ghost else { toggleBox(id); return }   // 動かさなかった = クリック
        ghost.removeFromSuperview()
        line.removeFromSuperview()
        if target > from { target -= 1 }
        guard target != from, !isEditing else { return }
        boxes.insert(boxes.remove(at: from), at: target)
        saveBoxes()
        shown.insert(shown.remove(at: from), at: target)
        collection.performBatchUpdates({ collection.moveSection(from, toSection: target) })
    }

    @objc func openAllBoxes() { setAllBoxes(open: true) }
    @objc func closeAllBoxes() { setAllBoxes(open: false) }
    func setAllBoxes(open: Bool) {
        endEditing()
        for i in boxes.indices { boxes[i].open = open }
        saveBoxes()
        rebuild()
    }

    // 末尾に空の箱を足し、その入力欄にフォーカスする
    @objc func addBox() {
        endEditing()
        boxes.append(Box(filter: ""))
        saveBoxes()
        reload()
        let ip = IndexPath(item: 0, section: shown.count - 1)
        collection.layoutSubtreeIfNeeded()
        if let frame = collection.layoutAttributesForSupplementaryElement(ofKind: NSCollectionView.elementKindSectionHeader, at: ip)?.frame {
            collection.scrollToVisible(frame)
            collection.layoutSubtreeIfNeeded()
        }
        if let header = collection.supplementaryView(forElementKind: NSCollectionView.elementKindSectionHeader, at: ip) as? BoxHeader {
            window.makeFirstResponder(header.field)
        }
    }

    // MARK: - フォルダの読み込みと監視

    func reload() {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey, .fileSizeKey, .isDirectoryKey]
        let urls = folderURLs.flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        }
        func added(_ u: URL) -> Date {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast
        }
        files = urls.map { ($0, added($0)) }.sorted { $0.1 > $1.1 }.map { $0.0 }
        sizes = [:]
        for u in files {
            let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            sizes[u] = v?.isDirectory == true ? "フォルダ"
                : v?.fileSize.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
        }
        let alive = Set(files)
        thumbs = thumbs.filter { alive.contains($0.key) }
        rebuild()
    }

    // files を箱と検索語で振り分けて表示し直す (フォルダは読み直さない)
    func rebuild() {
        // 見出しの入力中に作り直すと文字が消える。編集が終われば setFilter → reload から呼ばれる
        if isEditing { return }
        let hits = searchHits()
        // 選択は番号ではなく (箱, ファイル) で持ち越す。新着や箱の増減で並びがずれても別のファイルへ移らないように
        let selected = Set(collection.selectionIndexPaths.compactMap { ip in url(at: ip).map { "\(shown[ip.section].box.id)/\($0.path)" } })
        shown = boxes.map { box in (box, box.filtered(hits)) }
        collection.reloadData()
        var restore = Set<IndexPath>()
        for (s, entry) in shown.enumerated() where entry.box.open {
            for (i, u) in entry.files.enumerated() where selected.contains("\(entry.box.id)/\(u.path)") {
                restore.insert(IndexPath(item: i, section: s))
            }
        }
        if let target = selectAfterReload, files.contains(target) {
            selectAfterReload = nil
            restore = []
            for (s, entry) in shown.enumerated() where entry.box.open {
                if let i = entry.files.firstIndex(of: target) { restore.insert(IndexPath(item: i, section: s)) }
            }
        }
        collection.selectionIndexPaths = restore
        if let first = restore.min() { collection.scrollToItems(at: [first], scrollPosition: .nearestHorizontalEdge) }
        updateTrashButton()
    }

    // 検索語で絞ったファイル (フォルダは読み直さない)
    func searchHits() -> [URL] {
        let words = searchWords
        return files.filter { u in words.allSatisfy { u.lastPathComponent.localizedStandardContains($0) } }
    }

    func url(at ip: IndexPath) -> URL? {
        guard shown.indices.contains(ip.section), shown[ip.section].box.open else { return nil }
        let files = shown[ip.section].files
        return files.indices.contains(ip.item) ? files[ip.item] : nil
    }

    // 各フォルダ自体の書き込みイベントで再読込。ダウンロード中は連続で来るので 0.3 秒まとめる
    func startWatching() {
        for folder in folderURLs { watch(folder) }
    }

    func watch(_ folder: URL) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self, !self.reloadPending else { return }
            self.reloadPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.reloadPending = false
                self.reload()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        watchers.append(src)
    }

    // MARK: - サムネイル

    func thumbnail(for url: URL, completion: @escaping (NSImage) -> Void) {
        if let img = thumbs[url] { completion(img); return }
        let scale = window.backingScaleFactor
        let req = QLThumbnailGenerator.Request(fileAt: url, size: thumbSize, scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            DispatchQueue.main.async {
                let img = rep?.nsImage ?? NSWorkspace.shared.icon(forFile: url.path)
                self.thumbs[url] = img
                completion(img)
            }
        }
    }

    // MARK: - NSCollectionView

    func numberOfSections(in cv: NSCollectionView) -> Int { shown.count }

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        shown[section].box.open ? shown[section].files.count : 0
    }

    func collectionView(_ cv: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at ip: IndexPath) -> NSView {
        let header = cv.makeSupplementaryView(ofKind: kind, withIdentifier: BoxHeader.id, for: ip) as! BoxHeader
        header.owner = self
        header.configure(shown[ip.section].box, fileCount: shown[ip.section].files.count)
        return header
    }

    // 横に並ぶ数は「サムネイル枠 (96+8) が収まるだけ」で決め、余りはセル幅に均等に配る。
    // 固定幅 (96+16) だと Mac 本体の画面 (幅 1/3 ≒ 469) で 4 列に 3px 足りず、3 列でスカスカになっていた
    func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt ip: IndexPath) -> NSSize {
        let minW = thumbSize.width + 8, gap: CGFloat = 4
        let avail = cv.bounds.width - 12   // 左右の sectionInset
        if shown[ip.section].box.list {
            let url = shown[ip.section].files[ip.item]
            return NSSize(width: avail, height: ShelfListItem.height(name: url.lastPathComponent, size: sizes[url] ?? "", rowWidth: avail))
        }
        let n = max(1, floor((avail + gap) / (minW + gap)))
        return NSSize(width: floor((avail - gap * (n - 1)) / n), height: ShelfItem.height)
    }

    // リストは行間を詰める
    func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, minimumLineSpacingForSectionAt section: Int) -> CGFloat {
        shown[section].box.list ? 0 : 4
    }

    func windowDidResize(_ notification: Notification) {
        collection.collectionViewLayout?.invalidateLayout()
    }

    // 閉じた箱は見出しだけの高さにする
    func collectionView(_ cv: NSCollectionView, layout: NSCollectionViewLayout, insetForSectionAt section: Int) -> NSEdgeInsets {
        shown[section].box.open && !shown[section].files.isEmpty
            ? NSEdgeInsets(top: 4, left: 6, bottom: 10, right: 6) : NSEdgeInsets(top: 0, left: 6, bottom: 4, right: 6)
    }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        if shown[ip.section].box.list {
            let row = cv.makeItem(withIdentifier: ShelfListItem.id, for: ip) as! ShelfListItem
            let url = shown[ip.section].files[ip.item]
            row.url = url
            row.name = url.lastPathComponent
            row.sizeLabel.stringValue = sizes[url] ?? ""
            row.icon.image = NSWorkspace.shared.icon(forFile: url.path)
            return row
        }
        let item = cv.makeItem(withIdentifier: ShelfItem.id, for: ip) as! ShelfItem
        let url = shown[ip.section].files[ip.item]
        item.url = url
        item.name = url.lastPathComponent
        item.sizeLabel.stringValue = sizes[url] ?? ""
        item.thumb.image = thumbs[url]
        if thumbs[url] == nil {
            thumbnail(for: url) { img in
                if item.url == url { item.thumb.image = img }   // 再利用されたセルには描かない
            }
        }
        return item
    }

    func collectionView(_ cv: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ cv: NSCollectionView, pasteboardWriterForItemAt ip: IndexPath) -> NSPasteboardWriting? {
        url(at: ip) as NSURL?
    }

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateTrashButton()
    }
    func collectionView(_ cv: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) { updateTrashButton() }

    // MARK: - タイトルバー右端のボタン (全部開く・全部閉じる・箱の追加・ゴミ箱)

    // 文字の小さい角丸ボタン (Mac 標準の見た目)。文言は Finder の言い回しに合わせ、幅は全部同じ
    func addTitlebarButtons() {
        func button(_ title: String, _ action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            return b
        }
        plusButton = button("箱を追加", #selector(addBox))
        trashButton = button("ゴミ箱に入れる", #selector(trashSelected))
        renameButton = button("名前を変更", #selector(renameSelected))
        let buttons = [button("すべて開く", #selector(openAllBoxes)), button("すべて閉じる", #selector(closeAllBoxes)),
                       plusButton!, renameButton!, trashButton!]
        // 幅は文字数に合わせず、いちばん長い文言のボタンに揃える
        let width = buttons.map { $0.fittingSize.width }.max() ?? 0
        for b in buttons { b.widthAnchor.constraint(equalToConstant: width).isActive = true }
        let stack = NSStackView(views: buttons)
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 8)
        stack.frame.size = NSSize(width: stack.fittingSize.width, height: 28)
        let acc = NSTitlebarAccessoryViewController()
        acc.view = stack
        acc.layoutAttribute = .trailing
        window.addTitlebarAccessoryViewController(acc)
        updateTrashButton()
    }

    func updateTrashButton() {
        trashButton?.isEnabled = !collection.selectionIndexPaths.isEmpty
        renameButton?.isEnabled = renameTarget != nil
        updatePreview()
    }

    // 選択が変わるたびに呼ばれる (updateTrashButton 経由)。選択が 1 つの時だけ出し、複数・無しなら空にする。
    // 同じファイルのままなら差し替えない (フォルダの再読込のたびに動画が頭に戻る・ちらつくのを防ぐ)
    func updatePreview() {
        let url = renameTarget
        guard (preview.previewItem as? URL) != url else { return }
        preview.previewItem = url as NSURL?
        ClaudeContext.write(preview: url)   // claude が話しかけられた時に読む
    }

    // 選択中のファイル。同じファイルが複数の箱で選ばれていても 1 つに数える
    var selectedURLs: [URL] { Array(Set(collection.selectionIndexPaths.compactMap { url(at: $0) })) }

    // 選択中のファイルをゴミ箱へ。同じファイルが複数の箱で選ばれていても 1 回だけ渡す
    @objc func trashSelected() {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }
        collection.deselectAll(nil)
        updateTrashButton()
        // Finder のゴミ箱と同じ扱い (「戻す」が効く)。表示はフォルダ監視の再読込で消える
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error { NSLog("[DownloadsShelf] recycle failed: \(error)") }
        }
    }
    // MARK: - 名前の変更

    // 名前を入れるシート。最初は拡張子を除いた部分を選択しておく (Finder と同じ)
    // 名前を変える対象 (プレビューの対象も同じ): シェルフで選んだ 1 つ
    var renameTarget: URL? {
        let urls = selectedURLs
        return urls.count == 1 ? urls[0] : nil
    }

    @objc func renameSelected() {
        guard window.attachedSheet == nil else { return }
        guard let src = renameTarget else { return }
        let old = src.lastPathComponent
        let field = NSTextField(string: old)
        field.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.isScrollable = true
        let alert = NSAlert()
        alert.messageText = "名前を変更"
        alert.informativeText = "「\(old)」の新しい名前:"
        alert.accessoryView = field
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            self.confirmExtension(src, field.stringValue)
        }
        DispatchQueue.main.async {
            let ext = (old as NSString).pathExtension
            let base = ext.isEmpty || old.hasPrefix(".") ? old.utf16.count : old.utf16.count - ext.utf16.count - 1
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: base)
        }
    }

    // 拡張子が変わる時は一度止める (開くアプリが変わるため。Finder と同じ確認)
    func confirmExtension(_ src: URL, _ name: String) {
        let oldExt = src.pathExtension, newExt = (name as NSString).pathExtension
        guard oldExt.lowercased() != newExt.lowercased() else { rename(src, to: name); return }
        let alert = NSAlert()
        alert.messageText = newExt.isEmpty ? "拡張子「.\(oldExt)」を取り除きますか?"
            : oldExt.isEmpty ? "拡張子「.\(newExt)」を付けますか?" : "拡張子を「.\(oldExt)」から「.\(newExt)」に変えますか?"
        alert.informativeText = "変えると、別のアプリで開かれるようになる場合があります。"
        alert.addButton(withTitle: "変更")
        alert.addButton(withTitle: "キャンセル")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { self.rename(src, to: name) }
        }
    }

    // 手順 (ファイルを失わないための工夫) は RenameFile.swift の renameInPlace の説明
    func rename(_ src: URL, to name: String) {
        switch renameInPlace(src, to: name) {
        case .unchanged:
            return
        case .rejected(let reason), .failed(let reason):
            showRenameError(src.lastPathComponent, reason)
        case .renamed(let dst):
            // 表示はフォルダ監視の再読込で更新される。その時に新しい名前のファイルを選択し直す
            selectAfterReload = dst
        }
    }

    func showRenameError(_ old: String, _ reason: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "「\(old)」の名前を変更できませんでした"
        alert.informativeText = reason + "\nファイルは元の名前のまま残っています。"
        alert.beginSheetModal(for: window)
    }
}
