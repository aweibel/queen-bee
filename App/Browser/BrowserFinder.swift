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
    static func download(into support: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> Found {
        let (listed, _) = try await URLSession.shared.data(from: listing)
        let builds = try JSONValue.parse(listed)["channels"]?["Stable"]?["downloads"]?["chrome"]?.arrayValue ?? []
        guard let address = builds.first(where: { $0["platform"]?.stringValue == "mac-arm64" })?["url"]?.stringValue,
              let url = URL(string: address), url.scheme == "https",
              // The listing says where the build is. It is only fetched from Google's own storage.
              let host = url.host, host == "storage.googleapis.com" || host.hasSuffix(".googleapis.com") || host.hasSuffix(".google.com")
        else { throw BrowserError("Queen Bee couldn't find a browser to download") }

        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BrowserError("The browser download was refused") }
        let total = Double(max(response.expectedContentLength, 1))
        let fm = FileManager.default
        let folder = downloadFolder(in: support)
        try? fm.removeItem(at: folder)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let archive = folder.appendingPathComponent("chrome.zip")
        fm.createFile(atPath: archive.path, contents: nil)
        let handle = try FileHandle(forWritingTo: archive)
        var block = Data()
        block.reserveCapacity(1 << 20)
        var written = 0.0
        for try await byte in bytes {
            block.append(byte)
            if block.count >= 1 << 20 {
                try handle.write(contentsOf: block)
                written += Double(block.count)
                block.removeAll(keepingCapacity: true)
                await progress(min(written / total, 1))
            }
        }
        try handle.write(contentsOf: block)
        try handle.close()

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
