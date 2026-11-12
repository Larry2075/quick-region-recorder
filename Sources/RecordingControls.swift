import AppKit
import CoreGraphics

final class RecorderButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class RecordingControls: NSObject {
    private let panel: NSPanel
    private let indicator = NSImageView()
    private let title = NSTextField(labelWithString: "正在准备录屏")
    private let elapsed = NSTextField(labelWithString: "00:00")
    private let stopButton = RecorderButton(title: "停止", target: nil, action: nil)
    private let onStop: () -> Void
    private var ticker: Task<Void, Never>?

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init(region: CaptureRegion, onStop: @escaping () -> Void) {
        let size = NSSize(width: 272, height: 52)
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        self.onStop = onStop
        super.init()
        panel.title = "录屏控制"
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.appearance = NSAppearance(named: .darkAqua)

        let background = NSView(frame: NSRect(origin: .zero, size: size))
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.98).cgColor
        background.layer?.cornerRadius = 12
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
        panel.contentView = background

        indicator.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        indicator.contentTintColor = .secondaryLabelColor
        indicator.setAccessibilityElement(false)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        elapsed.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        stopButton.isEnabled = false
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.setAccessibilityLabel("停止录屏")

        let row = NSStackView(views: [indicator, title, elapsed, stopButton])
        row.alignment = .centerY
        row.distribution = .equalSpacing
        row.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 14),
            indicator.heightAnchor.constraint(equalToConstant: 14)
        ])

        if let screen = NSScreen.screens.first(where: { $0.captureDisplayID == region.displayID }) ?? NSScreen.main {
            let capture = NSRect(
                x: screen.frame.minX + region.rect.minX,
                y: screen.frame.maxY - region.rect.maxY,
                width: region.rect.width,
                height: region.rect.height
            )
            panel.setFrameOrigin(Self.position(size: size, in: screen.visibleFrame, avoiding: capture))
        }
        panel.orderFrontRegardless()
    }

    func recordingStarted() {
        title.stringValue = "正在录屏"
        indicator.contentTintColor = .systemRed
        stopButton.isEnabled = true
        let startedAt = ContinuousClock.now
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = Int(startedAt.duration(to: .now).components.seconds)
                guard let elapsed = self?.elapsed else { return }
                elapsed.stringValue = String(format: "%02d:%02d", seconds / 60, seconds % 60)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func recordingStopped() {
        ticker?.cancel()
        title.stringValue = "正在保存"
        indicator.contentTintColor = .secondaryLabelColor
        stopButton.isEnabled = false
    }

    func dismiss() {
        ticker?.cancel()
        panel.orderOut(nil)
    }

    @objc private func stopClicked() {
        onStop()
    }

    private static func position(size: NSSize, in visibleFrame: NSRect, avoiding capture: NSRect) -> NSPoint {
        let area = visibleFrame.insetBy(dx: 14, dy: 14)
        let right = area.maxX - size.width
        let top = area.maxY - size.height
        let corners = [
            NSPoint(x: right, y: top),
            NSPoint(x: area.minX, y: top),
            NSPoint(x: right, y: area.minY),
            NSPoint(x: area.minX, y: area.minY)
        ]
        return corners.min { a, b in
            let first = NSRect(origin: a, size: size).intersection(capture)
            let second = NSRect(origin: b, size: size).intersection(capture)
            return first.width * first.height < second.width * second.height
        } ?? corners[0]
    }
}
