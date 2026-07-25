import Foundation

/// The row order an open session menu holds on to.
///
/// `StateStore` sorts by status and then by `updatedAt`, and every hook event
/// bumps `updatedAt`, so a pair of busy agents reshuffles the list several
/// times a second. That is the right behavior for a list nobody is pointing
/// at, and the wrong one for a list with an open row: the option the pointer
/// is travelling toward slides out from under it, and AppKit does not
/// re-resolve hover for a view that moved beneath a motionless cursor — the
/// highlight stays wherever it last entered, which reads as a frozen menu.
///
/// So the menu pins the order it opened with. A session keeps its slot for as
/// long as it is on screen, newcomers land at the end where they displace
/// nothing, and the fresh sort arrives with the next opening.
public struct PinnedSessionOrder: Equatable, Sendable {
    private var sessionIDs: [String] = []

    public init() {}

    /// Learns sessions the pin has not seen yet, in the order given, and
    /// forgets the ones that have left the list. Deliberately additive:
    /// re-recording must never renumber a slot that is already pinned, or the
    /// pin would drift back toward the store's live ordering.
    public mutating func record(_ sessions: [AgentSession]) {
        let liveSessionIDs = Set(sessions.map(\.id))
        sessionIDs.removeAll { !liveSessionIDs.contains($0) }
        var known = Set(sessionIDs)
        for sessionID in sessions.map(\.id) where known.insert(sessionID).inserted {
            sessionIDs.append(sessionID)
        }
    }

    /// `sessions` in pinned order: pinned sessions first, each in its recorded
    /// slot, then anything unrecorded in the order it arrived. An empty pin
    /// hands the store's own ordering back untouched, so the first render of a
    /// freshly opened menu is already correct.
    public func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        guard !sessionIDs.isEmpty else { return sessions }
        let slotsBySessionID = Dictionary(
            sessionIDs.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: min
        )
        // A stable partition rather than a sort: unpinned sessions have no
        // slot to compare and must keep their relative arrival order.
        var pinned: [(slot: Int, session: AgentSession)] = []
        var unpinned: [AgentSession] = []
        for session in sessions {
            if let slot = slotsBySessionID[session.id] {
                pinned.append((slot, session))
            } else {
                unpinned.append(session)
            }
        }
        return pinned.sorted { $0.slot < $1.slot }.map(\.session) + unpinned
    }
}
