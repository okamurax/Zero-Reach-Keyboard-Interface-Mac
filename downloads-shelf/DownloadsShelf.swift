// ~/Downloads をサムネイルで並べ、他アプリへドラッグで渡すための置き場。
// Finder の窓状態 (ツールバー/サイドバー非表示) は次に開く Finder 窓へ引き継がれるため、
// 見た目を Finder と切り離す目的で専用アプリにしている。
// - 新しい順 (追加日) に並べ、フォルダの変更を監視して自動更新する
// - ドラッグは file URL を渡すので Finder からのドラッグと同じ扱いになる
// - ダブルクリックで既定アプリで開く。Esc / 閉じるボタンでアプリごと隠す
// - 窓は常に最前面 (floating)。出し入れと配置は Hammerspoon の英数+E が行う
// 削除・リネーム等のファイル操作は持たない (Finder に任せる)。

import AppKit
import QuickLookThumbnailing

let downloadsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
let thumbSize = CGSize(width: 96, height: 96)

final class ShelfItem: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("ShelfItem")
    let frameBox = NSBox()   // サムネイルの外枠。縦横比の違う画像でもアイテムの範囲が分かるように
    let thumb = NSImageView()
    let label = NSTextField(labelWithString: "")
    var url: URL?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        // NSBox の custom 型はライト/ダーク切替で色を追従してくれる
        frameBox.boxType = .custom
        frameBox.borderColor = .separatorColor
        frameBox.fillColor = NSColor.labelColor.withAlphaComponent(0.04)
        frameBox.borderWidth = 1
        frameBox.cornerRadius = 6
        frameBox.contentViewMargins = .zero
        frameBox.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(frameBox)
        v.addSubview(thumb)
        v.addSubview(label)
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
        ])
        view = v
    }

    override var isSelected: Bool {
        didSet { view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : nil }
    }
}

// - アイテム上: ダブルクリックで開く。1回目のクリックは通常どおり選択・ドラッグに回す
// - アイテム外の余白: 窓の移動に使う (範囲選択の矩形ドラッグは捨てる。複数選択は ⌘/⇧クリックで)
final class ShelfCollectionView: NSCollectionView {
    var onOpen: ((IndexPath) -> Void)?
    override func mouseDown(with event: NSEvent) {
        guard let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else {
            deselectAll(nil)
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
    override func cancelOperation(_ sender: Any?) { NSApp.hide(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSCollectionViewDataSource, NSCollectionViewDelegate, NSWindowDelegate {
    var window: ShelfWindow!
    var collection: ShelfCollectionView!
    var files: [URL] = []
    var thumbs: [URL: NSImage] = [:]   // キーは path+更新日時を含めたい所だが、上書きダウンロードは稀なので URL で十分
    var watcher: DispatchSourceFileSystemObject?
    var reloadPending = false

    func applicationDidFinishLaunching(_ note: Notification) {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: thumbSize.width + 16, height: thumbSize.height + 34)
        layout.minimumInteritemSpacing = 4
        layout.minimumLineSpacing = 4
        layout.sectionInset = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)

        collection = ShelfCollectionView()
        collection.collectionViewLayout = layout
        collection.isSelectable = true
        collection.allowsMultipleSelection = true
        collection.backgroundColors = [.clear]
        collection.dataSource = self
        collection.delegate = self
        collection.register(ShelfItem.self, forItemWithIdentifier: ShelfItem.id)
        collection.setDraggingSourceOperationMask(.every, forLocal: false)
        collection.onOpen = { [weak self] ip in
            guard let self else { return }
            NSWorkspace.shared.open(self.files[ip.item])
        }

        let scroll = NSScrollView()
        scroll.documentView = collection
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        window = ShelfWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 450),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
        window.title = FileManager.default.displayName(atPath: downloadsURL.path)   // 日本語環境では「ダウンロード」
        window.isMovableByWindowBackground = true   // ファイルが少なく collection view が窓を埋めない時の下側余白用
        window.level = .floating
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentView = scroll

        reload()
        startWatching()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Dock アイコンが無い (LSUIElement) ので、再度 open / activate されたら窓を出し直す
    func applicationDidBecomeActive(_ note: Notification) {
        if window?.isMiniaturized == true { window.deminiaturize(nil) }
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationDidUnhide(_ note: Notification) {
        reload()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.hide(nil)
        return false
    }

    // MARK: - フォルダの読み込みと監視

    func reload() {
        let keys: [URLResourceKey] = [.addedToDirectoryDateKey, .creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: keys,
                                                                 options: [.skipsHiddenFiles])) ?? []
        func added(_ u: URL) -> Date {
            let v = try? u.resourceValues(forKeys: Set(keys))
            return v?.addedToDirectoryDate ?? v?.creationDate ?? .distantPast
        }
        files = urls.map { ($0, added($0)) }.sorted { $0.1 > $1.1 }.map { $0.0 }
        let alive = Set(files)
        thumbs = thumbs.filter { alive.contains($0.key) }
        collection.reloadData()
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

    func collectionView(_ cv: NSCollectionView, numberOfItemsInSection section: Int) -> Int { files.count }

    func collectionView(_ cv: NSCollectionView, itemForRepresentedObjectAt ip: IndexPath) -> NSCollectionViewItem {
        let item = cv.makeItem(withIdentifier: ShelfItem.id, for: ip) as! ShelfItem
        let url = files[ip.item]
        item.url = url
        item.label.stringValue = url.lastPathComponent
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
        files[ip.item] as NSURL
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
