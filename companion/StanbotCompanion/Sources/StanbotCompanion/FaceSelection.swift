import Foundation

/// Spatial continuity only: this does not recognize identity or infer eye contact.
struct FaceSelection {
    enum State: String {
        case searching = "No stable face detected"
        case acquiring = "Confirming face"
        case tracking = "Face selected"
        case uncertain = "Target uncertain"
    }
    private(set) var state: State = .searching
    private(set) var box: FaceBox?
    private var candidate: FaceBox?
    private var hits = 0
    private var lastSeen: TimeInterval = -.infinity
    private var lastUpdate: TimeInterval = -.infinity
    /// Smoothed spacing between updates, so tolerance can be expressed in
    /// missed frames rather than in seconds. Fixed second-based thresholds
    /// silently require a minimum frame rate: with a 0.9 s loss window and the
    /// three consecutive hits below, anything slower than about 3.3 fps could
    /// never lock on at all, and failed by looking like a detection problem.
    /// Measured on 2026-09-15 at 0.93 fps, where it never left "Confirming".
    private var interval: TimeInterval = 0.3
    /// Whether `interval` reflects a real measurement yet. Until a second frame
    /// arrives the rate is genuinely unknown, and assuming a fast stream would
    /// discard the first hit before the frame that would confirm it ever lands.
    private var sampled = false

    /// Roughly one and a half frames without the selected face, then four.
    /// Floors keep a fast stream from becoming twitchy; ceilings stop a very
    /// slow one from holding a stale box forever.
    private var uncertainAfter: TimeInterval {
        sampled ? min(max(interval * 1.5, 0.4), 2.0) : 0.75
    }
    private var lostAfter: TimeInterval {
        sampled ? min(max(interval * 3.0, 0.8), 4.0) : 1.5
    }

    /// Keeps the learned frame interval: it describes the transport, not the
    /// face, and relearning it from scratch after every reset reintroduces
    /// exactly the failure above on a slow stream.
    mutating func reset() {
        let learned = (interval, sampled)
        self = Self()
        (interval, sampled) = learned
    }

    mutating func expire(at now: TimeInterval) {
        if now - lastSeen >= lostAfter { reset() }
        else if now - lastSeen >= uncertainAfter, state == .tracking {
            state = .uncertain
            box = nil
        }
    }

    mutating func update(_ observations: [FaceBox], at now: TimeInterval) {
        guard now > lastUpdate else { return }
        // Sample the spacing before expire(), which may reset.
        if lastUpdate.isFinite {
            let sample = min(max(now - lastUpdate, 0.02), 2.0)
            interval += 0.3 * (sample - interval)
            sampled = true
        }
        expire(at: now)
        lastUpdate = now
        let valid = observations.filter {
            let r = $0.rect
            return $0.confidence.isFinite && $0.confidence >= 0.7 &&
                [r.origin.x, r.origin.y, r.width, r.height].allSatisfy(\.isFinite) &&
                r.width >= 0.03 && r.height >= 0.03 && r.minX >= 0 && r.minY >= 0 &&
                r.maxX <= 1 && r.maxY <= 1
        }
        if let previous = candidate {
            // A detection continues the selection if it overlaps it, or if its
            // centre is within 1.2 face widths. Overlap alone broke whenever the
            // face moved in the frame: during head following on 2026-09-16 the
            // head's own turn slid the face far enough between frames (~5 fps)
            // that the smoothed box stopped overlapping, the lock dropped, and no
            // targets were sent for up to 10 s.
            let gate = 1.2 * previous.rect.width
            let near = valid
                .map { (box: $0, distance: centreDistance(previous.rect, $0.rect)) }
                .filter { overlap(previous.rect, $0.box.rect) >= 0.2 || $0.distance <= gate }
                .sorted { $0.distance < $1.distance }
            // Two faces near the selection are ambiguous unless one is clearly
            // nearer; ambiguity is never permission to switch people.
            let unambiguous = near.count == 1 || (near.count > 1 && near[1].distance >= 2 * near[0].distance + 0.02)
            let matches = unambiguous ? [near[0].box] : near.map(\.box)
            guard matches.count == 1, let match = matches.first else {
                box = nil
                // Two things used to be conflated here. Several faces overlapping
                // the selection is real ambiguity, and ambiguity is not permission
                // to switch to a different person. Simply not seeing the selected
                // face in one frame is a miss, and a miss must not destroy
                // progress: expire() above decides when it is genuinely lost,
                // now in units of missed frames. Discarding partial progress on
                // any single miss is what kept acquisition permanently at one hit.
                if matches.count > 1, hits < 3 { reset() }
                else if hits >= 3 { state = .uncertain }
                return
            }
            let alpha = 0.8   // follows a moving face closely; 0.65 lagged enough to break the match
            let old = previous.rect, new = match.rect
            let smooth = CGRect(x: old.minX + alpha * (new.minX - old.minX),
                                y: old.minY + alpha * (new.minY - old.minY),
                                width: old.width + alpha * (new.width - old.width),
                                height: old.height + alpha * (new.height - old.height))
            candidate = FaceBox(id: previous.id, rect: smooth, confidence: match.confidence)
            hits += 1
        } else {
            // Initial selection is deterministic: largest, then closest to center.
            candidate = valid.sorted {
                let a = $0.rect.width * $0.rect.height, b = $1.rect.width * $1.rect.height
                if a != b { return a > b }
                return abs($0.rect.midX - 0.5) < abs($1.rect.midX - 0.5)
            }.first
            guard candidate != nil else { state = .searching; return }
            hits = 1
        }
        lastSeen = now
        state = hits >= 3 ? .tracking : .acquiring
        box = hits >= 3 ? candidate : nil
    }

    private func centreDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        return area / (a.width * a.height + b.width * b.height - area)
    }
}
