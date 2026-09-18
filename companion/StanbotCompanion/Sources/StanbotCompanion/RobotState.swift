import Foundation

/// State the Mac keeps on the robot's behalf, and hands back when it connects.
///
/// Three kinds of thing survive a reset here, and they live in three different
/// places on purpose (docs/head-following.md, "State that survives a reset"):
///
/// - **Measured constants** -- the yaw centre, pitch level, the limits -- live
///   in the firmware source, in git, because they are findings and belong in
///   history and review.
/// - **What the robot needs with nobody there** -- the Wi-Fi profiles, the OTA
///   passphrase -- live in the robot's own NVS, because it must work alone.
/// - **Guesses and preferences** -- where someone usually is -- live *here*.
///   A value the robot keeps to itself cannot be shown, diffed or cleared from
///   the Mac, and a stale one that quietly biases where the head looks is the
///   kind of bug that eats an afternoon.
///
/// The robot does not know any of this. It is told one place to look first; the
/// learning is all on this side, where it can be inspected and reset.
enum RobotState {
    struct Place: Equatable {
        let yaw: Int, pitch: Int
    }

    /// How many recent sightings are kept. A few days of sitting down at the
    /// same desk, not a history.
    static let remembered = 8
    /// Two sightings within this of each other are the same place. 64 raw is
    /// 20 degrees -- a chair's worth, not a room's.
    static let sameePlaceRaw = 64
    /// Consecutive look arounds that checked the usual place and found nobody,
    /// after which it stops being led with. **This is the whole resilience
    /// story**: the robot sits on a desk and can be nudged round, and the owner
    /// may simply be somewhere else that day. Either way every stored place is
    /// then wrong -- by the same offset if the robot moved -- and a prior that
    /// cannot be disbelieved would aim at a wall for ever. Two misses is enough
    /// to stop trusting it; one sighting anywhere is enough to start again.
    static let missesBeforeDoubt = 2

    static let sightingsKey = "StanbotSightings"
    static let missesKey = "StanbotPriorMisses"
    // Kept for the one-line upgrade from the single-value form.
    static let lastSeenYawKey = "StanbotLastSeenYaw"
    static let lastSeenPitchKey = "StanbotLastSeenPitch"

    /// Recent sightings, oldest first.
    static var sightings: [Place] {
        get {
            let stored = UserDefaults.standard.array(forKey: sightingsKey) as? [[Int]] ?? []
            let places = stored.compactMap { $0.count == 2 ? Place(yaw: $0[0], pitch: $0[1]) : nil }
            if !places.isEmpty { return places }
            // Whatever the single-value form knew, so an upgrade does not forget.
            guard let old = lastSeen else { return [] }
            return [old]
        }
        set {
            UserDefaults.standard.set(newValue.suffix(remembered).map { [$0.yaw, $0.pitch] }, forKey: sightingsKey)
        }
    }

    /// Consecutive look arounds that led with the usual place and found nobody.
    static var priorMisses: Int {
        get { UserDefaults.standard.integer(forKey: missesKey) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: missesKey) }
    }

    /// The single most recent sighting. Still written, so a downgrade or an
    /// older reader keeps working.
    static var lastSeen: Place? {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: lastSeenYawKey) != nil,
                  defaults.object(forKey: lastSeenPitchKey) != nil else { return nil }
            return Place(yaw: defaults.integer(forKey: lastSeenYawKey),
                         pitch: defaults.integer(forKey: lastSeenPitchKey))
        }
        set {
            let defaults = UserDefaults.standard
            guard let newValue else {
                defaults.removeObject(forKey: lastSeenYawKey)
                defaults.removeObject(forKey: lastSeenPitchKey)
                return
            }
            defaults.set(newValue.yaw, forKey: lastSeenYawKey)
            defaults.set(newValue.pitch, forKey: lastSeenPitchKey)
        }
    }

    /// Somebody was seen here. Ends any doubt about the usual place: whatever
    /// had gone wrong -- the robot moved, they sat elsewhere -- this is now
    /// evidence, and two more sightings like it make it the new usual place.
    static func rememberLastSeen(yaw: Int, pitch: Int) {
        let place = Place(yaw: yaw, pitch: pitch)
        sightings = sightings + [place]
        lastSeen = place
        priorMisses = 0
    }

    /// A look around led with the usual place and found nobody there.
    static func priorMissed() { priorMisses += 1 }

    /// Where to look first, or nil to sweep the room without a guess.
    ///
    /// The **densest cluster** of recent sightings, not their average: an
    /// average of the desk and the doorway is the wall between them, where
    /// nobody has ever been. Ties go to the more recent cluster, so moving
    /// desks takes a few sittings rather than for ever. Returns the cluster's
    /// middle sighting -- a real place someone was, not a computed one.
    static func usualPlace(_ places: [Place]? = nil, misses: Int? = nil) -> Place? {
        let history = places ?? sightings
        guard !history.isEmpty else { return nil }
        guard (misses ?? priorMisses) < missesBeforeDoubt else { return nil }
        var best: (members: [Place], newest: Int)?
        for (index, candidate) in history.enumerated() {
            let members = history.enumerated().filter { abs($0.element.yaw - candidate.yaw) <= sameePlaceRaw }
            let newest = members.map(\.offset).max() ?? index
            if best == nil || members.count > best!.members.count
                || (members.count == best!.members.count && newest > best!.newest) {
                best = (members.map(\.element), newest)
            }
        }
        guard let cluster = best?.members, !cluster.isEmpty else { return nil }
        return cluster.sorted { $0.yaw < $1.yaw }[cluster.count / 2]
    }

    /// The line that hands it back, or nil when there is nothing worth handing.
    static func restoreLine(_ place: Place?) -> String? {
        guard let place else { return nil }
        return "K,lsy=\(place.yaw),lsp=\(place.pitch)\n"
    }

    /// Forget everything learned about where people are. The robot has been
    /// moved, or the room has changed, and none of it is evidence any more.
    static func forgetSightings() {
        UserDefaults.standard.removeObject(forKey: sightingsKey)
        lastSeen = nil
        priorMisses = 0
    }
}
