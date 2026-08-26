import Foundation

/// Whose word wins when this phone deleted a conversation the second place still holds.
///
/// AC10. The local deletion is the OWNER's decision and the remote is a copy, so deletion wins
/// — a merge that resurrects a deleted conversation quietly undoes an act the owner performed
/// deliberately, which is worse than a deletion that visibly fails.
///
/// ⚠ NO INCARNATION FIELD IS REQUIRED, and AC-C5 was withdrawn on that basis.
/// `CaptureManager.newCaptureId()` mints `omi-<stamp>-<uuid8>` with a FRESH uuid, so a
/// re-recorded conversation never carries a tombstoned id and suppression by id is exact. The
/// invariant is pinned by `testMintedIdsAreNeverReused`, so if minting ever stops guaranteeing
/// it, that test fails and the withdrawal is revisited rather than silently invalidated.
public enum DeletionPrecedence {

    /// Remote rows minus the ones this phone deleted.
    public static func apply(
        remote: [ConversationHit],
        locallyDeleted: Set<String>
    ) -> [ConversationHit] {
        guard !locallyDeleted.isEmpty else { return remote }
        return remote.filter { !locallyDeleted.contains($0.captureId) }
    }
}
