// ~/Downloads をサムネイルで並べ、他アプリへドラッグで渡すための置き場。
// Finder の窓状態 (ツールバー/サイドバー非表示) は次に開く Finder 窓へ引き継がれるため、
// 見た目を Finder と切り離す目的で専用アプリにしている。
// - 新しい順 (追加日) に並べ、フォルダの変更を監視して自動更新する
// - ドラッグは file URL を渡すので Finder からのドラッグと同じ扱いになる
// - ダブルクリックで既定アプリで開く。Esc / 閉じるボタンでアプリごと隠す
// - 名前の下にファイルサイズ (Finder と同じ表記)
// - タイトルバー右端の「ゴミ箱に入れる」で、選択中のファイルをゴミ箱へ移す (選択が無い時は押せない)
//   以前は一覧の先頭にゴミ箱セルを置いてドラッグで落とす方式だったが、同じ窓内のドロップが安定せず
//   (Esc 取り消しでも消える・ハイライトが一瞬で消える等) 撤去した
// - 英数+E (Karabiner が ⌃⌥⌘F16 を送る) を自前の Carbon ホットキーで受ける。普通の窓なので他の窓の後ろにも回る
//   - 手前にある → 隠す / 後ろにある → 手前に出す (位置はそのまま)
//   - 隠れている → カーソルのある画面の右端 (幅 1/3・自作タスクバーを除いた全高) に置いてから出す
//   以前は Hammerspoon が unhide → 窓の出現をポーリング → setFrame していたが、古い位置に一瞬出てから
//   飛ぶうえに遅かったため、配置してから表示するまでをアプリ内で一度に行う
// - 起動は Hammerspoon が起動時に裏で行う (常駐)。起動直後は窓を出さない
// - 一覧は上下に並ぶ「箱」に分かれる。箱ごとに表示する拡張子を指定 (例: "xls, xlsx"、"*" で全部)
//   - 箱は見え方だけ。同じファイルが複数の箱に出てよい。指定は入力欄からフォーカスが外れた時点で反映
//   - 箱は横幅いっぱい・高さはファイル数なり。見出しの ▸ で閉じると見出しだけになる
//   - タイトルバーの「箱を追加」で追加、見出しの × で削除。「すべて開く / すべて閉じる」もタイトルバーに構成は UserDefaults に保存
// - 箱の上の検索欄でファイル名を絞り込む (打つたびに反映、全部の箱が対象)。× か Esc で消すと元の表示に戻る
//   - 空白区切りは AND。大文字小文字・全角半角は区別しない
//   - 箱ごとにサムネイル / リスト表示を切り替えられる (見出しの右のボタン)
//   - 見出しをクリックで開閉、上下にドラッグで並べ替え (入力欄・ボタン以外の部分)
// - 配色は Mattermost のサイドバー (既定テーマ Denim、背景はより濃く) に寄せている。ライト/ダークに関係なく固定
// ゴミ箱へ移す以外のファイル操作 (リネーム等) は持たない (Finder に任せる)。

import AppKit
import Carbon.HIToolbox
import QuickLookThumbnailing

let downloadsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
let thumbSize = CGSize(width: 96, height: 96)
// 自作タスクバー (hammerspoon/taskbar.lua の BAR_H=43) + 窓との隙間 (init.lua の TASKBAR_GAP=8)
let taskbarInset: CGFloat = 43 + 8

// Mattermost Denim テーマのサイドバー色。背景だけ Denim (#1e325c) より濃くしている
let mmSidebar = NSColor(srgbRed: 0x11 / 255.0, green: 0x1a / 255.0, blue: 0x28 / 255.0, alpha: 1)
let mmAccent = NSColor(srgbRed: 0x5d / 255.0, green: 0x89 / 255.0, blue: 0xea / 255.0, alpha: 1)
let mmText = NSColor.white.withAlphaComponent(0.64)   // 見出し・非アクティブ文字
let mmHover = NSColor.white.withAlphaComponent(0.08)

final class ShelfItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ShelfItem")
    let frameBox = NSBox()   // サムネイルの外枠。縦横比の違う画像でもアイテムの範囲が分かるように
    let thumb = NSImageView()
    let label = NSTextField(labelWithString: "")
    let sizeLabel = NSTextField(labelWithString: "")
    var url: URL?

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
        label.font = .systemFont(ofSize: 11)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
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
            label.topAnchor.constraint(equalTo: frameBox.bottomAnchor, constant: 2),
            label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -2),
            sizeLabel.topAnchor.constraint(equalTo: label.bottomAnchor),
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

    // "xls, .xlsx *.mp4" → ["xls","xlsx","mp4"]。"*" を含めば nil (全部)
    var extensions: Set<String>? {
        let words = filter.lowercased().split { ", ;、　".contains($0) }.map(String.init)
        if words.contains("*") { return nil }
        return Set(words.map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0.hasPrefix(".") ? String($0.dropFirst()) : $0 })
    }

    func shows(_ url: URL) -> Bool {
        guard let exts = extensions else { return true }
        return exts.contains(url.pathExtension.lowercased())
    }
}

// リスト表示の 1 行: アイコン・名前・サイズ
final class ShelfListItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ShelfListItem")
    let icon = NSImageView()
    let label = NSTextField(labelWithString: "")
    let sizeLabel = NSTextField(labelWithString: "")
    var url: URL?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 4
        icon.imageScaling = .scaleProportionallyUpOrDown
        label.font = .systemFont(ofSize: 12)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        sizeLabel.font = .systemFont(ofSize: 11)
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
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            sizeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            sizeLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            sizeLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        view = v
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? mmAccent.withAlphaComponent(0.45).cgColor : nil }
    }
}

// 箱の見出し (Mattermost のサイドバーのカテゴリ見出し風): ▾/▸・拡張子の入力欄・件数・× (ホバー時だけ)
// 入力欄とボタン以外の部分は、クリックで開閉・上下ドラッグで並べ替え
final class BoxHeader: NSView, NSCollectionViewElement, NSTextFieldDelegate {
    static let id = NSUserInterfaceItemIdentifier("BoxHeader")
    let toggle = NSButton()
    let field = NSTextField()
    let count = NSTextField(labelWithString: "")
    let remove = NSButton()
    let mode = NSButton()   // サムネイル / リスト切替
    var boxID: UUID?
    weak var owner: AppDelegate?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 4
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
        field.placeholderAttributedString = NSAttributedString(string: "拡張子", attributes: [
            .foregroundColor: NSColor.white.withAlphaComponent(0.32), .font: NSFont.systemFont(ofSize: 12, weight: .semibold)])
        field.toolTip = "表示する拡張子 (例: xls, xlsx)。* で全部"
        field.delegate = self
        count.font = .systemFont(ofSize: 11)
        count.textColor = NSColor.white.withAlphaComponent(0.4)
        remove.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "箱を削除")
        remove.symbolConfiguration = symbol
        remove.contentTintColor = mmText
        remove.isBordered = false
        remove.isHidden = true
        remove.toolTip = "この箱を削除 (ファイルは消えない)"
        remove.target = self
        remove.action = #selector(removeTapped)
        mode.symbolConfiguration = symbol
        mode.contentTintColor = mmText
        mode.isBordered = false
        mode.target = self
        mode.action = #selector(modeTapped)
        for v in [toggle, field, count, mode, remove] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            toggle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: toggle.trailingAnchor, constant: 4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            // 固定幅にして、右側の空きを掴める場所として残す (編集可能な欄は文字幅を持たないので広がってしまう)
            field.widthAnchor.constraint(equalToConstant: 120),
            count.trailingAnchor.constraint(equalTo: mode.leadingAnchor, constant: -8),
            mode.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -6),
            mode.centerYAnchor.constraint(equalTo: centerYAnchor),
            mode.widthAnchor.constraint(equalToConstant: 18),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            remove.centerYAnchor.constraint(equalTo: centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ box: Box, fileCount: Int) {
        boxID = box.id
        if field.currentEditor() == nil { field.stringValue = box.filter }
        toggle.image = NSImage(systemSymbolName: box.open ? "chevron.down" : "chevron.right",
                               accessibilityDescription: box.open ? "閉じる" : "開く")
        count.stringValue = "\(fileCount)"
        // 押すと切り替わる先の表示を絵にする
        mode.image = NSImage(systemSymbolName: box.list ? "square.grid.2x2" : "list.bullet",
                             accessibilityDescription: box.list ? "サムネイル表示にする" : "リスト表示にする")
        mode.toolTip = box.list ? "サムネイル表示にする" : "リスト表示にする"
        setHover(false)
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
        layer?.backgroundColor = on ? mmHover.cgColor : nil
        remove.isHidden = !on
    }

    // 窓は isMovableByWindowBackground なので、これが無いと見出しを掴んだ時に窓ごと動いて並べ替えにならない
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if let boxID { owner?.trackHeaderDrag(boxID, header: self, down: event) }
    }

    @objc func toggleTapped() { if let boxID { owner?.toggleBox(boxID) } }
    @objc func modeTapped() { if let boxID { owner?.toggleListMode(boxID) } }
    @objc func removeTapped() { if let boxID { owner?.removeBox(boxID) } }
    // Enter・Tab・別の場所のクリックのどれでも来る (確定ボタンは置かない)
    func controlTextDidEndEditing(_ obj: Notification) {
        if let boxID { owner?.setFilter(boxID, field.stringValue, from: field) }
    }
}

// - アイテム上: ダブルクリックで開く。1回目のクリックは通常どおり選択・ドラッグに回す
// - アイテム外の余白: 窓の移動に使う (範囲選択の矩形ドラッグは捨てる。複数選択は ⌘/⇧クリックで)
final class ShelfCollectionView: NSCollectionView {
    var onOpen: ((IndexPath) -> Void)?
    var onDeselectAll: (() -> Void)?   // コードからの選択解除はデリゲートに通知されないため
    override func mouseDown(with event: NSEvent) {
        guard let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else {
            window?.makeFirstResponder(self)   // 入力欄の編集をここで終わらせる (= 拡張子の反映)
            deselectAll(nil)
            onDeselectAll?()
            window?.performDrag(with: event)
            return
        }
        if event.clickCount == 2 {
            onOpen?(ip)
            return
        }
        super.mouseDown(with: event)
    }
}

// 通常の窓 (信号機ボタンは Finder と同じ 3 つ)。utility パネルだとボタンが小さい別物になるため使わない
final class ShelfWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.hide() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout, NSWindowDelegate, NSTextFieldDelegate {
    var window: ShelfWindow!
    var collection: ShelfCollectionView!
    var boxes: [Box] = []
    // 表示中の内容。boxes を書き換えてから reload() するまでの間も、collection view はこちらだけを見る
    var shown: [(box: Box, files: [URL])] = []
    var plusButton: NSButton!
    var files: [URL] = []   // フォルダの中身 (新しい順)。箱と検索での振り分け前
    let searchField = NSTextField()
    var clearButton: NSButton!
    var trashButton: NSButton!
    var sizes: [URL: String] = [:]
    var thumbs: [URL: NSImage] = [:]   // キーは path+更新日時を含めたい所だが、上書きダウンロードは稀なので URL で十分
    var watcher: DispatchSourceFileSystemObject?
    var reloadPending = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: thumbSize.width + 16, height: thumbSize.height + 48)
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
        collection.setDraggingSourceOperationMask(.every, forLocal: false)
        // 開くのはクリックしたセルが表示しているファイル (再読込で並びがずれても取り違えない)
        collection.onDeselectAll = { [weak self] in self?.updateTrashButton() }
        collection.onOpen = { [weak self] ip in
            let item = self?.collection.item(at: ip)
            guard let url = (item as? ShelfItem)?.url ?? (item as? ShelfListItem)?.url else { return }
            NSWorkspace.shared.open(url)
        }

        let scroll = NSScrollView()
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
        window.isMovableByWindowBackground = true   // ファイルが少なく collection view が窓を埋めない時の下側余白用
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        let searchBar = makeSearchBar()
        let content = NSView()
        for v in [searchBar, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: content.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            searchBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: 36),
            scroll.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
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
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let vis = screen?.visibleFrame {   // visibleFrame で右配置 Dock とメニューバーを避ける
            let w = floor(vis.width / 3)
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

    // 前のアプリにフォーカスが戻る。編集中の拡張子は隠す前に確定させる
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
            boxes = [Box(filter: "*")]
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
        boxes[i].open.toggle()
        saveBoxes()
        reload()
    }

    func toggleListMode(_ id: UUID) {
        endEditing()
        guard let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        boxes[i].list.toggle()
        saveBoxes()
        reload()
    }

    func removeBox(_ id: UUID) {
        endEditing()
        boxes.removeAll { $0.id == id }
        saveBoxes()
        reload()
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
        guard target != from, let i = boxes.firstIndex(where: { $0.id == id }) else { return }
        boxes.insert(boxes.remove(at: i), at: min(target, boxes.count))
        saveBoxes()
        reload()
    }

    @objc func openAllBoxes() { setAllBoxes(open: true) }
    @objc func closeAllBoxes() { setAllBoxes(open: false) }
    func setAllBoxes(open: Bool) {
        endEditing()
        for i in boxes.indices { boxes[i].open = open }
        saveBoxes()
        reload()
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
        let urls = (try? FileManager.default.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
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
        let words = searchWords
        let hits = files.filter { u in words.allSatisfy { u.lastPathComponent.localizedStandardContains($0) } }
        // 選択は番号ではなく (箱, ファイル) で持ち越す。新着や箱の増減で並びがずれても別のファイルへ移らないように
        let selected = Set(collection.selectionIndexPaths.compactMap { ip in url(at: ip).map { "\(shown[ip.section].box.id)/\($0.path)" } })
        shown = boxes.map { box in (box, hits.filter { box.shows($0) }) }
        collection.reloadData()
        var restore = Set<IndexPath>()
        for (s, entry) in shown.enumerated() where entry.box.open {
            for (i, u) in entry.files.enumerated() where selected.contains("\(entry.box.id)/\(u.path)") {
                restore.insert(IndexPath(item: i, section: s))
            }
        }
        collection.selectionIndexPaths = restore
        updateTrashButton()
    }

    func url(at ip: IndexPath) -> URL? {
        guard shown.indices.contains(ip.section), shown[ip.section].box.open else { return nil }
        let files = shown[ip.section].files
        return files.indices.contains(ip.item) ? files[ip.item] : nil
    }

    // ディレクトリ自体の書き込みイベントで再読込。ダウンロード中は連続で来るので 0.3 秒まとめる
    func startWatching() {
        let fd = open(downloadsURL.path, O_EVTONLY)
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
        watcher = src
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
        if shown[ip.section].box.list { return NSSize(width: avail, height: 26) }
        let n = max(1, floor((avail + gap) / (minW + gap)))
        return NSSize(width: floor((avail - gap * (n - 1)) / n), height: thumbSize.height + 48)
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
            row.label.stringValue = url.lastPathComponent
            row.sizeLabel.stringValue = sizes[url] ?? ""
            row.icon.image = NSWorkspace.shared.icon(forFile: url.path)
            return row
        }
        let item = cv.makeItem(withIdentifier: ShelfItem.id, for: ip) as! ShelfItem
        let url = shown[ip.section].files[ip.item]
        item.url = url
        item.label.stringValue = url.lastPathComponent
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

    func collectionView(_ cv: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) { updateTrashButton() }
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
        let buttons = [button("すべて開く", #selector(openAllBoxes)), button("すべて閉じる", #selector(closeAllBoxes)),
                       plusButton!, trashButton!]
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
    }

    // 選択中のファイルをゴミ箱へ。同じファイルが複数の箱で選ばれていても 1 回だけ渡す
    @objc func trashSelected() {
        let urls = Array(Set(collection.selectionIndexPaths.compactMap { url(at: $0) }))
        guard !urls.isEmpty else { return }
        collection.deselectAll(nil)
        updateTrashButton()
        // Finder のゴミ箱と同じ扱い (「戻す」が効く)。表示はフォルダ監視の再読込で消える
        NSWorkspace.shared.recycle(urls) { _, error in
            if let error { NSLog("[DownloadsShelf] recycle failed: \(error)") }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
