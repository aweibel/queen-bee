import Foundation

/// One setting while it is being changed from a device: what the Mac has, what the person has written, and
/// how far that has got. The Mac is told when the field is left or after a pause, never on every key, so for
/// a while the two differ. This says which is on show, and it needs no screen: the iPad and iPhone app's
/// settings call it, and the tests call it without one.
///
/// The rules it keeps:
/// - While the field is being written in, or holds something the Mac hasn't taken, a change from the Mac is
///   remembered and not shown. When neither is so, the field follows the Mac.
/// - Sending sends what was written, whatever the Mac has by then: the last to write wins, as on the Mac.
/// - What the Mac refuses stays in the field, with the Mac's words. What couldn't go because the Mac can't
///   be reached stays too, marked as not saved.
public struct FieldEdit<Value: Equatable & Sendable>: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Nothing of the person's is in it. It shows what the Mac has.
        case untouched
        /// Written here and not yet sent.
        case edited
        /// On its way to the Mac.
        case sending
        /// The Mac wouldn't take it. The words are the Mac's.
        case refused(String)
        /// It couldn't be sent, because the Mac can't be reached. It is kept, to be sent when asked again.
        case unsaved
    }

    /// What the Mac last said the setting is.
    public private(set) var mac: Value
    /// What the person has written, when it isn't what the Mac has.
    public private(set) var draft: Value?
    public private(set) var state = State.untouched
    /// The keyboard is in the field.
    public private(set) var hasFocus = false
    /// What left for the Mac and hasn't been answered.
    private var inFlight: Value?
    /// What the Mac just took, shown until the Mac's own copy arrives, so the field doesn't flick back.
    private var taken: Value?
    /// What the field showed when the keyboard came into it, kept on show while nothing has been written.
    private var held: Value?

    public init(mac: Value) { self.mac = mac }

    /// What the Mac is taken to have: what it just took from here, until its own copy says.
    private var believed: Value { taken ?? mac }

    /// What the field shows.
    public var shown: Value { draft ?? held ?? taken ?? mac }

    /// True while a change from the Mac must not be shown in the field.
    public var isBeingEdited: Bool { hasFocus || draft != nil }

    /// True when there is nothing here the Mac doesn't have, so the field can be forgotten.
    public var isIdle: Bool { !hasFocus && draft == nil && taken == nil && state == .untouched }

    /// True when what was written should go to the Mac and isn't on its way.
    public var needsSending: Bool { draft != nil && state == .edited }

    /// The keyboard came into the field, or left it.
    public mutating func setFocus(_ on: Bool) {
        guard on != hasFocus else { return }
        hasFocus = on
        held = on && draft == nil ? shown : nil
    }

    /// The person changed what is in the field.
    public mutating func write(_ value: Value) {
        guard value != shown else { return }
        held = hasFocus ? value : nil
        if value == believed, state != .sending {
            // Written back to what the Mac has: there is nothing to send. What the Mac has is what it last
            // took from here, when its own copy of that hasn't arrived yet.
            draft = nil
            state = .untouched
            return
        }
        draft = value
        if state != .sending { state = .edited }
    }

    /// The Mac's copy of the flow has arrived, with this in the setting.
    public mutating func macHas(_ value: Value) {
        mac = value
        taken = nil
        // The Mac has come to what was written, by another hand. There is nothing left to send.
        if draft == value, state != .sending {
            draft = nil
            state = .untouched
            if hasFocus { held = value }
        }
    }

    /// Call when it is time to tell the Mac. Returns what to send, or nil when there is nothing to send or
    /// something is already on its way.
    public mutating func send() -> Value? {
        guard state != .sending, let draft else { return nil }
        guard draft != believed else {
            self.draft = nil
            state = .untouched
            if hasFocus { held = believed }
            return nil
        }
        inFlight = draft
        state = .sending
        return draft
    }

    /// The Mac answered what was sent. No refusal means it took it. `unreachable` is for an answer that
    /// never came because there is no Mac to hear: what was written is kept as not saved.
    public mutating func answered(_ refusal: String?, unreachable: Bool = false) {
        guard state == .sending else { return }
        let sent = inFlight
        inFlight = nil
        guard draft == sent else {
            // More was written while it was on its way. That is what counts now.
            state = .edited
            return
        }
        if let refusal {
            state = unreachable ? .unsaved : .refused(refusal)
        } else {
            draft = nil
            // Nothing to keep on show when the Mac's copy got here before its answer did.
            taken = sent == mac ? nil : sent
            if hasFocus { held = sent }
            state = .untouched
        }
    }

    /// Throws away what was written and goes back to what the Mac has.
    public mutating func discard() {
        draft = nil
        taken = nil
        inFlight = nil
        held = hasFocus ? mac : nil
        state = .untouched
    }
}
