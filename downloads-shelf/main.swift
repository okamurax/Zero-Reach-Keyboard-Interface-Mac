// 起動。複数ファイルをまとめてビルドする時、起動の命令は main.swift にしか書けないためここに置く
import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
