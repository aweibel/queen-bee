import Foundation

/// Where Claude Code keeps a session's transcript, and what that means for starting the session again.
///
/// Claude Code saves each conversation as `~/.claude/projects/<folder>/<session id>.jsonl`, where `<folder>` is
/// the directory the session ran in with everything but letters and digits turned into "-". `--resume` only looks
/// in the folder of the directory it is started in, so a conversation begun in one folder can't be resumed from
/// another.
public enum Transcripts {
    /// Past this many characters Claude Code cuts the folder name short and adds a hash of the whole path.
    static let longestFolderName = 200

    /// The name Claude Code gives the transcripts folder of `directory`, before any cutting short.
    public static func folderName(for directory: String) -> String {
        // Counted as JavaScript counts: a character outside the Basic Multilingual Plane is two.
        String(directory.utf16.map { unit -> Character in
            switch unit {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A: Character(Unicode.Scalar(unit)!)
            default: "-"
            }
        })
    }

    /// Whether `name`, a folder under `~/.claude/projects`, is the one Claude Code uses for `directory`. A long
    /// path's folder ends in a hash this can't work out, so only the part before it is compared.
    public static func isFolder(_ name: String, for directory: String) -> Bool {
        let full = folderName(for: directory)
        guard full.count > longestFolderName else { return name == full }
        return name.hasPrefix(String(full.prefix(longestFolderName)) + "-")
    }

    /// How a session should be started, given where its transcript is.
    public enum Start: Equatable, Sendable {
        /// The transcript is in the folder the session starts in: carry on with it.
        case resume
        /// There is no transcript anywhere: start a new conversation under the same id.
        case fresh
        /// The transcript is in another folder, as after the card's folder was changed. It can't be resumed from
        /// here, and its id is taken, so the session starts a new conversation under a new id.
        case freshWithNewID
    }

    public static func start(inFolder: Bool, elsewhere: Bool) -> Start {
        inFolder ? .resume : elsewhere ? .freshWithNewID : .fresh
    }
}
