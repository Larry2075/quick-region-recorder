import AppKit
import FinderSync
import OSLog

final class RecorderFinderSync: FIFinderSync {
    private let logger = Logger(subsystem: "com.kongdexi.quick-region-recorder", category: "Finder")

    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/", isDirectory: true),
            URL(fileURLWithPath: "/Volumes", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
        ]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForContainer else { return nil }
        logger.info("Building the region recording item for the Finder background menu")
        let menu = NSMenu()
        let item = NSMenuItem(title: "区域录屏", action: #selector(selectRegion), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func selectRegion() {
        let appURL = Bundle(for: RecorderFinderSync.self).bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let options = NSWorkspace.OpenConfiguration()
        options.activates = false
        NSWorkspace.shared.open([RecorderCommand.selectRegion], withApplicationAt: appURL, configuration: options) {
            [logger] _, error in
            if let error {
                logger.error("Could not open the recorder: \(error.localizedDescription, privacy: .public)")
                DispatchQueue.main.async { NSSound.beep() }
            }
        }
    }
}
