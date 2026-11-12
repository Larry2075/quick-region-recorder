import AppKit
import Foundation

@main
enum ChromeHost {
    private struct Request: Decodable {
        let action: String
    }

    private struct Response: Encodable {
        let ok: Bool
        let message: String?
    }

    @MainActor
    static func main() async {
        do {
            let input = FileHandle.standardInput
            let header = input.readData(ofLength: 4)
            guard header.count == 4 else { return }
            let size = Int(header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            guard (1...4096).contains(size) else {
                try respond(ok: false, message: "请求长度无效。")
                return
            }

            let request = try JSONDecoder().decode(Request.self, from: input.readData(ofLength: size))
            guard request.action == "select-region" else {
                try respond(ok: false, message: "不支持此操作。")
                return
            }

            let bundleID = "com.kongdexi.quick-region-recorder"
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  Bundle(url: appURL)?.bundleIdentifier == bundleID else {
                try respond(ok: false, message: "找不到已安装的快捷录屏。")
                return
            }

            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            _ = try await NSWorkspace.shared.open([RecorderCommand.selectRegion], withApplicationAt: appURL, configuration: options)
            try respond(ok: true)
        } catch {
            try? respond(ok: false, message: error.localizedDescription)
        }
    }

    private static func respond(ok: Bool, message: String? = nil) throws {
        let payload = try JSONEncoder().encode(Response(ok: ok, message: message))
        var length = UInt32(payload.count)
        let output = FileHandle.standardOutput
        try withUnsafeBytes(of: &length) { try output.write(contentsOf: $0) }
        try output.write(contentsOf: payload)
    }
}
