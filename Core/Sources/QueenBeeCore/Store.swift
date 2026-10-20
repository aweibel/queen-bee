import Foundation

/// A flow and the file it was loaded from.
public struct FlowFile: Equatable, Sendable {
    public let url: URL
    public var flow: Flow

    public init(url: URL, flow: Flow) { self.url = url; self.flow = flow }
}

/// Reads and writes a project's flows, one JSON file each.
public struct FlowStore: Sendable {
    /// The project folder.
    public let root: URL

    public init(root: URL) { self.root = root }

    private var home: URL { root.appendingPathComponent(".queenbee", isDirectory: true) }
    public var directory: URL { home.appendingPathComponent("flows", isDirectory: true) }

    /// Every flow in the project, sorted by file name. A file that doesn't parse, comes from another version,
    /// has an id the app could not have made (`Flow.hasSafeIDs`), or repeats the id of a flow already loaded
    /// is listed as unreadable instead.
    public func loadAll() -> (flows: [FlowFile], unreadable: [URL]) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }
            .sorted()
        var flows: [FlowFile] = []
        var unreadable: [URL] = []
        var seen: Set<String> = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            // A file a crash left empty or cut short is the version before it, which is kept beside it for this.
            if let flow = Self.read(url) ?? (Self.isDamaged(url) ? Self.read(Self.backupURL(for: url)) : nil), seen.insert(flow.id).inserted {
                flows.append(FlowFile(url: url, flow: flow))
            } else {
                unreadable.append(url)
            }
        }
        return (flows, unreadable)
    }

    /// Writes the flow and returns where it went. With no url it picks a new file name from the flow's name.
    @discardableResult
    public func save(_ flow: Flow, to url: URL?) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        // Flows hold session ids and local paths, so the folder is kept out of git unless the person opts in.
        let ignore = home.appendingPathComponent(".gitignore")
        if !files.fileExists(atPath: ignore.path) { try Data("*\n".utf8).write(to: ignore) }

        let target = url ?? freeURL(for: flow)
        let folder = target.deletingLastPathComponent()
        try files.createDirectory(at: folder, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(flow)
        data.append(0x0A)

        // Written whole beside the target, flushed to the disk itself, and renamed over it, so neither a crash
        // nor a power cut leaves half a flow, or an empty file where the flow was.
        let temp = folder.appendingPathComponent(".\(target.lastPathComponent).\(Flow.newID()).tmp")
        do {
            try Self.writeDurably(data, to: temp)
        } catch {
            try? files.removeItem(at: temp)
            throw error
        }
        // The version being replaced is kept, as long as it is a flow this app can read. A new file has none,
        // and whatever was kept for an earlier file of that name is not this flow's.
        let backup = Self.backupURL(for: target)
        unlink(backup.path)
        if Self.read(target) != nil { link(target.path, backup.path) }
        guard rename(temp.path, target.path) == 0 else {
            let code = errno
            try? files.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // The rename itself is only safe once the folder that records it is on the disk too.
        let folderHandle = open(folder.path, O_RDONLY)
        if folderHandle >= 0 {
            fsync(folderHandle)
            close(folderHandle)
        }
        return target
    }

    public func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        unlink(Self.backupURL(for: url).path)
    }

    /// Where the version of a flow file before the last save is kept: hidden, beside it.
    public static func backupURL(for url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).bak")
    }

    private static func writeDurably(_ data: Data, to url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = FileHandle(forWritingAtPath: url.path) else { throw POSIXError(.EIO) }
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        // fsync leaves the data in the drive's own cache, where a power cut still loses it. F_FULLFSYNC doesn't.
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0, fsync(handle.fileDescriptor) != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// True for a file that is empty or isn't JSON at all, as a crash in the middle of writing leaves one. A file
    /// that is whole but can't be loaded, such as one from a newer version of the app, is not damaged.
    private static func isDamaged(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return data.isEmpty || (try? JSONSerialization.jsonObject(with: data)) == nil
    }

    /// Lowercase letters, digits and dashes, 40 characters at most, "flow" if nothing is left.
    public static func slug(_ name: String) -> String {
        var slug = ""
        for character in name.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                slug.append(character)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        slug = String(slug.prefix(40))
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "flow" : slug
    }

    // MARK: -

    private static func read(_ url: URL) -> Flow? {
        guard let data = try? Data(contentsOf: url),
              var flow = try? JSONDecoder().decode(Flow.self, from: data),
              flow.version == Flow.currentVersion, flow.hasSafeIDs else { return nil }
        // A kind of card that has gained an output since the file was written, as Loop until did, gets the room for it.
        for index in flow.cards.indices {
            flow.cards[index].height = max(flow.cards[index].height, Card.minimumHeight(for: flow.cards[index]))
        }
        return flow
    }

    /// A file name nothing else is using. A file that already holds this same flow counts as free,
    /// because saving beside it would leave two files with one id and make the second unreadable.
    private func freeURL(for flow: Flow) -> URL {
        let slug = Self.slug(flow.name)
        func free(_ name: String) -> URL? {
            let url = directory.appendingPathComponent(name + ".json")
            if !FileManager.default.fileExists(atPath: url.path) || Self.read(url)?.id == flow.id { return url }
            return nil
        }
        if let url = free(slug) ?? free("\(slug)-\(flow.id.prefix(4))") ?? free("\(slug)-\(flow.id)") { return url }
        var n = 2
        while true {
            if let url = free("\(slug)-\(flow.id)-\(n)") { return url }
            n += 1
        }
    }
}
