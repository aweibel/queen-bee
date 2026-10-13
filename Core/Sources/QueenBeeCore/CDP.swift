import Foundation

/// How the app and a Chromium browser talk over the browser's remote-control pipe: JSON messages, each ended by
/// a zero byte.
public enum CDP {
    /// One command, framed for the pipe. `sessionID` aims it at one tab; without it the browser itself answers.
    public static func command(id: Int, method: String, params: JSONValue = [:], sessionID: String? = nil) -> Data {
        var message: [String: JSONValue] = ["id": .number(Double(id)), "method": .string(method), "params": params]
        if let sessionID { message["sessionId"] = .string(sessionID) }
        var data = JSONValue.object(message).data()
        data.append(0)
        return data
    }

    /// Takes every whole message off the front of `buffer`, leaving what has only partly arrived.
    public static func messages(from buffer: inout Data) -> [Data] {
        var found: [Data] = []
        while let end = buffer.firstIndex(of: 0) {
            let body = Data(buffer[buffer.startIndex..<end])
            buffer = Data(buffer[(end + 1)...])
            if !body.isEmpty { found.append(body) }
        }
        return found
    }
}
