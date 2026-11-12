import AppKit
import CoreGraphics

struct CaptureRegion {
    let displayID: CGDirectDisplayID
    // Display-local points measured from the top-left, as ScreenCaptureKit expects.
    let rect: CGRect
}

extension NSScreen {
    var captureDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor
final class RegionPicker {
    private var panels: [SelectionPanel] = []
    private var completion: ((CaptureRegion?) -> Void)?
    private var screenObserver: (any NSObjectProtocol)?

    func present(completion: @escaping (CaptureRegion?) -> Void) {
        self.completion = completion
        panels = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.captureDisplayID else { return nil }
            let panel = SelectionPanel(screen: screen)
            let canvas = SelectionView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                hintY: screen.frame.maxY - screen.visibleFrame.maxY + 24
            )
            canvas.onSelect = { [weak self] rect in
                self?.finish(CaptureRegion(displayID: displayID, rect: rect))
            }
            canvas.onCancel = { [weak self] in self?.finish(nil) }
            canvas.onDragStart = { [weak self] activeCanvas in
                for panel in self?.panels ?? [] {
                    guard let otherCanvas = panel.contentView as? SelectionView, otherCanvas !== activeCanvas else {
                        continue
                    }
                    otherCanvas.clearSelection()
                }
            }
            panel.contentView = canvas
            panel.initialFirstResponder = canvas
            panel.orderFrontRegardless()
            return panel
        }

        guard let panel = panels.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? panels.first else {
            finish(nil)
            return
        }
        panel.makeKey()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    private func finish(_ region: CaptureRegion?) {
        guard let completion else { return }
        self.completion = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        completion(region)
    }
}

private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

private final class SelectionView: NSView {
    var onSelect: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var onDragStart: ((SelectionView) -> Void)?
    private let hintY: CGFloat
    private var anchor: CGPoint?
    private var selection: CGRect?
    private let actions = NSStackView()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, hintY: CGFloat) {
        self.hintY = hintY
        super.init(frame: frame)
        let cancel = RecorderButton(title: "取消", target: self, action: #selector(cancelSelection))
        let start = RecorderButton(title: "开始录屏", target: self, action: #selector(confirmSelection))
        start.keyEquivalent = "\r"
        actions.addArrangedSubview(cancel)
        actions.addArrangedSubview(start)
        actions.spacing = 8
        actions.isHidden = true
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)
        NSLayoutConstraint.activate([
            actions.centerXAnchor.constraint(equalTo: centerXAnchor),
            actions.topAnchor.constraint(equalTo: topAnchor, constant: hintY + 10)
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: selection != nil && anchor == nil ? .arrow : .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onDragStart?(self)
        clearSelection()
        anchor = point(for: event)
    }

    override func mouseDragged(with event: NSEvent) {
        selection = rectangle(to: point(for: event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = rectangle(to: point(for: event))
        anchor = nil
        if let rect, rect.width >= 16, rect.height >= 16 {
            selection = rect
            actions.isHidden = false
        } else {
            clearSelection()
        }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func clearSelection() {
        anchor = nil
        selection = nil
        actions.isHidden = true
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    @objc private func confirmSelection() {
        guard anchor == nil, let selection, !actions.isHidden else { return }
        onSelect?(selection)
    }

    @objc private func cancelSelection() {
        onCancel?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if let selection {
            shade.appendRect(selection)
        }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.44).setFill()
        shade.fill()

        if let selection, !selection.isEmpty {
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 3
            NSColor.black.withAlphaComponent(0.8).setStroke()
            border.stroke()
            border.lineWidth = 1
            NSColor.white.setStroke()
            border.stroke()
            if !actions.isHidden {
                drawCapsule(around: actions.frame)
            }
        } else {
            drawHint()
        }
    }

    private func drawHint() {
        let hint = NSAttributedString(
            string: "拖动选择录屏区域   ·   Esc 取消",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.white
            ]
        )
        let size = hint.size()
        let textRect = NSRect(x: (bounds.width - size.width) / 2, y: hintY + 9, width: size.width, height: size.height)
        drawCapsule(around: textRect)
        hint.draw(in: textRect)
    }

    private func drawCapsule(around rect: CGRect) {
        let background = rect.insetBy(dx: -14, dy: -9)
        NSColor.black.withAlphaComponent(0.88).setFill()
        NSBezierPath(roundedRect: background, xRadius: 10, yRadius: 10).fill()
    }

    private func point(for event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    private func rectangle(to point: CGPoint) -> CGRect? {
        guard let anchor else { return nil }
        return CGRect(
            x: min(anchor.x, point.x), y: min(anchor.y, point.y),
            width: abs(anchor.x - point.x), height: abs(anchor.y - point.y)
        ).integral.intersection(bounds)
    }
}
