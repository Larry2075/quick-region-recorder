import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
final class RecordingSession: NSObject, SCRecordingOutputDelegate, SCStreamDelegate {
    private let onStart: () -> Void
    private var onFinish: ((Result<URL, Error>) -> Void)?
    private var stream: SCStream?
    private var outputURL: URL?
    private var stopping = false

    init(onStart: @escaping () -> Void, onFinish: @escaping (Result<URL, Error>) -> Void) {
        self.onStart = onStart
        self.onFinish = onFinish
    }

    static func outputDirectory() throws -> URL {
        let movies = try FileManager.default.url(
            for: .moviesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let directory = movies.appending(path: "快捷录屏", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func start(_ region: CaptureRegion, excludingWindow windowID: CGWindowID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
                throw RecordingError.displayUnavailable
            }
            let filter: SCContentFilter
            if let controls = content.windows.first(where: { $0.windowID == windowID }) {
                filter = SCContentFilter(display: display, excludingWindows: [controls])
            } else {
                let ownApplication = content.applications.filter {
                    $0.processID == ProcessInfo.processInfo.processIdentifier
                }
                filter = SCContentFilter(display: display, excludingApplications: ownApplication, exceptingWindows: [])
            }
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = region.rect
            configuration.captureResolution = .best
            let scale = min(CGFloat(filter.pointPixelScale), 4096 / max(region.rect.width, region.rect.height))
            // H.264 requires even dimensions for the chroma planes.
            configuration.width = max(2, Int(region.rect.width * scale) / 2 * 2)
            configuration.height = max(2, Int(region.rect.height * scale) / 2 * 2)
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
            configuration.showsCursor = true

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss.SSS"
            let url = try Self.outputDirectory()
                .appending(path: "录屏 \(formatter.string(from: Date())).mp4", directoryHint: .notDirectory)
            let fileConfiguration = SCRecordingOutputConfiguration()
            fileConfiguration.outputURL = url
            fileConfiguration.outputFileType = .mp4
            fileConfiguration.videoCodecType = .h264
            let output = SCRecordingOutput(configuration: fileConfiguration, delegate: self)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            try stream.addRecordingOutput(output)
            outputURL = url
            self.stream = stream
            try await stream.startCapture()
        } catch {
            finish(.failure(error))
        }
    }

    func stop() {
        guard !stopping, let stream else { return }
        stopping = true
        Task {
            do {
                try await stream.stopCapture()
            } catch let error as SCStreamError where error.code == .userStopped || error.code == .attemptToStopStreamState {
                // The system stop button may have already stopped this stream.
                // The recording output still reports when the file is finalized.
            } catch {
                finish(.failure(error))
            }
        }
    }

    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            if onFinish != nil { onStart() }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            if let outputURL { finish(.success(outputURL)) }
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in
            stop()
            finish(.failure(error))
        }
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        if let error = error as? SCStreamError, error.code == .userStopped { return }
        Task { @MainActor in finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let onFinish else { return }
        self.onFinish = nil
        stream = nil
        if case .failure = result, let outputURL,
           let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size == 0 {
            try? FileManager.default.removeItem(at: outputURL)
        }
        onFinish(result)
    }
}

private enum RecordingError: LocalizedError {
    case displayUnavailable

    var errorDescription: String? {
        "所选显示器已不可用。请重新框选录屏区域。"
    }
}
