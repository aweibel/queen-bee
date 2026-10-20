import Foundation
import QueenBeeCore
import Subprocess
import System

/// Where the browser that agent cards use comes from: one already on the Mac, or a copy of Chrome for Testing
/// that Queen Bee downloads for its own use.
enum BrowserFinder {
    struct Found: Equatable {
        var path: String
        /// The copy Queen Bee downloaded, not one the person installed.
        var isDownloaded: Bool
    }

    /// Chromium-based browsers that take the same remote control, in the order they are looked for.
    private static let installed = [
        "Google Chrome.app/Contents/MacOS/Google Chrome",
        "Chromium.app/Contents/MacOS/Chromium",
        "Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        "Brave Browser.app/Contents/MacOS/Brave Browser",
    ]

    private static func downloadFolder(in support: URL) -> URL {
        support.appendingPathComponent("browser-app", isDirectory: true)
    }

    private static func downloadedExecutable(in support: URL) -> URL {
        downloadFolder(in: support).appendingPathComponent(
            "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing")
    }

    static func find(support: URL) -> Found? {
        let fm = FileManager.default
        // A test can ask for a Mac with no browser on it.
        let skipsInstalled = TestHarness.isEnabled && ProcessInfo.processInfo.environment["QB_NO_INSTALLED_BROWSER"] != nil
        if !skipsInstalled {
            for folder in ["/Applications", NSHomeDirectory() + "/Applications"] {
                for relative in installed where fm.isExecutableFile(atPath: "\(folder)/\(relative)") {
                    return Found(path: "\(folder)/\(relative)", isDownloaded: false)
                }
            }
        }
        let downloaded = downloadedExecutable(in: support).path
        return fm.isExecutableFile(atPath: downloaded) ? Found(path: downloaded, isDownloaded: true) : nil
    }

    /// Where Google lists the current Chrome for Testing builds.
    private static let listing = URL(string: "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json")!

    /// Downloads Chrome for Testing into the app's support folder. `progress` gets a fraction from 0 to 1.
    static func download(into support: URL, progress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> Found {
        let (listed, _) = try await URLSession.shared.data(from: listing)
        let builds = try JSONValue.parse(listed)["channels"]?["Stable"]?["downloads"]?["chrome"]?.arrayValue ?? []
        guard let address = builds.first(where: { $0["platform"]?.stringValue == "mac-arm64" })?["url"]?.stringValue,
              let url = URL(string: address), url.scheme == "https",
              // The listing says where the build is. It is only fetched from Google's own storage.
              let host = url.host, host == "storage.googleapis.com" || host.hasSuffix(".googleapis.com") || host.hasSuffix(".google.com")
        else { throw BrowserError("Queen Bee couldn't find a browser to download") }

        let fm = FileManager.default
        let folder = downloadFolder(in: support)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("chrome.zip")
        // The system writes the file itself, off the main thread, and says how far it has got.
        try await ArchiveDownload(to: archive) { fraction in
            Task { @MainActor in progress(fraction) }
        }.run(url)

        let unpacked = try await run(.path("/usr/bin/ditto"), arguments: ["-x", "-k", archive.path, folder.path],
                                     output: .discarded, error: .discarded)
        try? fm.removeItem(at: archive)
        let executable = downloadedExecutable(in: support).path
        guard unpacked.terminationStatus.isSuccess, fm.isExecutableFile(atPath: executable) else {
            throw BrowserError("The downloaded browser couldn't be unpacked")
        }
        return Found(path: executable, isDownloaded: true)
    }
}

/// One file fetched by the system into `destination`, with its progress reported as it goes. The bytes never pass
/// through the app: the download is written to a temporary file and moved into place when it is whole.
private nonisolated final class ArchiveDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    /// Why the finished file wasn't taken, when it wasn't.
    private var problem: Error?
    private var reported = -1.0
    /// How the download ended, kept when it ended before `run` was waiting for it, as when it was cancelled at once.
    private var outcome: Result<Void, Error>?

    init(to destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func run(_ url: URL) async throws {
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let ended = lock.withLock {
                    if outcome == nil { self.continuation = continuation }
                    return outcome
                }
                if let ended { return continuation.resume(with: ended) }
                task.resume()
            }
        } onCancel: {
            // A task cancelled before it started still ends through the delegate, so `run` always hears.
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1)
        // Once a percent is plenty for a progress bar.
        let due = lock.withLock {
            guard fraction - reported >= 0.01 else { return false }
            reported = fraction
            return true
        }
        if due { progress(fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns, so it is moved now or never.
        let taken: Error?
        if (downloadTask.response as? HTTPURLResponse)?.statusCode != 200 {
            taken = BrowserError("The browser download was refused")
        } else {
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
                taken = nil
            } catch {
                taken = error
            }
        }
        lock.withLock { problem = taken }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let ended: Result<Void, Error> = (error ?? lock.withLock { problem }).map { .failure($0) } ?? .success(())
        let waiting = lock.withLock {
            defer { continuation = nil }
            if continuation == nil { outcome = ended }
            return continuation
        }
        waiting?.resume(with: ended)
    }
}
