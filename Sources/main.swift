import AppKit
import CoreGraphics

@MainActor
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private enum State {
        case idle, selecting, starting, recording, stopping
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let picker = RegionPicker()
    private var state = State.idle {
        didSet { updateIcon() }
    }
    private var recording: RecordingSession?
    private var recordingControls: RecordingControls?
    private var latestFile: URL?
    private var terminateAfterRecording = false
    private var showingAlert = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusClicked)
        updateIcon()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if urls.contains(RecorderCommand.selectRegion) {
            beginSelection()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard recording != nil else { return .terminateNow }
        terminateAfterRecording = true
        if state == .recording {
            stopRecording()
        }
        return .terminateLater
    }

    @objc private func statusClicked() {
        switch state {
        case .recording:
            stopRecording()
        case .idle:
            showMenu()
        case .selecting, .starting, .stopping:
            break
        }
    }

    private func showMenu() {
        guard let button = statusItem.button else { return }
        let menu = NSMenu()
        menu.addItem(item("区域录屏", action: #selector(beginSelection)))
        menu.addItem(.separator())
        if let latestFile, FileManager.default.fileExists(atPath: latestFile.path) {
            menu.addItem(item("在访达中显示刚录好的视频", action: #selector(revealLatest)))
        }
        menu.addItem(item("打开录屏文件夹", action: #selector(openFolder)))
        if !CGPreflightScreenCaptureAccess() {
            menu.addItem(item("录屏权限设置…", action: #selector(openPermissionSettings)))
        }
        menu.addItem(.separator())
        menu.addItem(item("退出快捷录屏", action: #selector(quit)))
        let bottom = button.isFlipped ? button.bounds.maxY : button.bounds.minY
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bottom), in: button)
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func beginSelection() {
        guard state == .idle, !showingAlert else { return }
        guard checkPermission() else { return }
        state = .selecting
        picker.present { [weak self] region in
            guard let self else { return }
            if let region {
                self.startRecording(region)
            } else {
                self.state = .idle
            }
        }
    }

    private func checkPermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let permissionRequested = "ScreenCapturePermissionRequested"
        if !UserDefaults.standard.bool(forKey: permissionRequested) {
            UserDefaults.standard.set(true, forKey: permissionRequested)
            NSApp.activate()
            return CGRequestScreenCaptureAccess()
        }
        showingAlert = true
        defer { showingAlert = false }
        let alert = NSAlert()
        alert.messageText = "请允许快捷录屏录制屏幕"
        alert.informativeText = "在系统设置的「屏幕与系统音频录制」中开启「快捷录屏」。如果系统提示重新打开应用，请按提示操作。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            openPermissionSettings()
        }
        return false
    }

    private func startRecording(_ region: CaptureRegion) {
        state = .starting
        let controls = RecordingControls(region: region) { [weak self] in
            self?.stopRecording()
        }
        recordingControls = controls
        let session = RecordingSession(onStart: { [weak self] in
            guard let self, self.state == .starting else { return }
            self.state = .recording
            self.recordingControls?.recordingStarted()
            if self.terminateAfterRecording {
                self.stopRecording()
            }
        }, onFinish: { [weak self] result in
            self?.recordingFinished(result)
        })
        recording = session
        let controlsWindowID = controls.windowID
        Task { await session.start(region, excludingWindow: controlsWindowID) }
    }

    private func stopRecording() {
        guard state == .recording else { return }
        state = .stopping
        recordingControls?.recordingStopped()
        recording?.stop()
    }

    private func recordingFinished(_ result: Result<URL, Error>) {
        recording = nil
        recordingControls?.dismiss()
        recordingControls = nil
        switch result {
        case .success(let url):
            latestFile = url
            state = .idle
        case .failure(let error):
            state = .idle
            showError("录屏未能完成", error)
        }
        if terminateAfterRecording {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let symbol: String
        let label: String
        switch state {
        case .idle:
            symbol = "record.circle"
            label = latestFile == nil ? "快捷录屏" : "录屏已保存"
        case .selecting:
            symbol = "viewfinder"
            label = "拖动框选录屏区域"
        case .starting:
            symbol = "hourglass"
            label = "正在开始录屏"
        case .recording:
            symbol = "stop.circle.fill"
            label = "正在录屏 · 点击停止"
        case .stopping:
            symbol = "hourglass"
            label = "正在保存录屏"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? NSImage(systemSymbolName: "record.circle", accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = state == .recording ? .systemRed : nil
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    @objc private func revealLatest() {
        if let latestFile {
            NSWorkspace.shared.activateFileViewerSelecting([latestFile])
        }
    }

    @objc private func openFolder() {
        do {
            NSWorkspace.shared.open(try RecordingSession.outputDirectory())
        } catch {
            showError("无法打开录屏文件夹", error)
        }
    }

    @objc private func openPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func showError(_ title: String, _ error: Error) {
        showingAlert = true
        defer { showingAlert = false }
        let alert = NSAlert(error: error)
        alert.informativeText = error.localizedDescription
        alert.messageText = title
        NSApp.activate()
        alert.runModal()
    }
}

let app = NSApplication.shared
let appDelegate = MenuBarApp()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
