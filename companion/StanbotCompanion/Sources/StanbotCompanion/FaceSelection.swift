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
    /// Smoothed motion of the selected face, in frame widths per second. Used
    /// to predict where it will be, so two people crossing are told apart by
    /// where each was heading rather than only by who is nearer this frame.
    private var velocity = CGVector(dx: 0, dy: 0)
    /// The unsmoothed centre of the last match. Prediction starts here, not at
    /// the smoothed box, which lags a moving face by design.
    private var lastCentre: CGPoint?
    /// Where the last confirmed face was when it was lost, so a person who
    /// steps out of view briefly is preferred on return over whoever is largest.
    private var lastLost: (centre: CGPoint, width: CGFloat, at: TimeInterval)?
    static let rememberLostFor: TimeInterval = 3

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

    /// A reset that remembers where a confirmed face was lost.
    private mutating func lose(at now: TimeInterval) {
        let lost = (hits >= 3 ? candidate : nil).map { (centre: CGPoint(x: $0.rect.midX, y: $0.rect.midY), width: $0.rect.width, at: now) }
        let remembered = lost ?? lastLost
        reset()
        lastLost = remembered
    }

    mutating func expire(at now: TimeInterval) {
        if now - lastSeen >= lostAfter { lose(at: now) }
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
        // A face near an edge usually has a box that runs past it: Vision
        // returns the whole head, including the part outside the image. Those
        // detections used to be discarded, which is worst exactly when it
        // matters, since a face at the edge is what the head should turn
        // toward. Measured on 2026-09-16: a face high in the frame was
        // detected every frame for 3.5 s at confidence 0.8 and reported as
        // "no stable face" throughout. They are now clipped to the frame, and
        // kept when enough of the face is still inside.
        let valid: [FaceBox] = observations.compactMap {
            let r = $0.rect
            guard $0.confidence.isFinite, $0.confidence >= 0.7,
                  [r.origin.x, r.origin.y, r.width, r.height].allSatisfy(\.isFinite),
                  r.width >= 0.03, r.height >= 0.03 else { return nil }
            let clipped = r.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !clipped.isNull, clipped.width >= 0.03, clipped.height >= 0.03,
                  clipped.width * clipped.height >= 0.5 * r.width * r.height else { return nil }
            return FaceBox(id: $0.id, rect: clipped, confidence: $0.confidence, pose: $0.pose, frameWidth: $0.frameWidth)
        }
        if let previous = candidate {
            // A detection continues the selection if it overlaps it, or if its
            // centre is within 1.2 face widths. Overlap alone broke whenever the
            // face moved in the frame: during head following on 2026-09-16 the
            // head's own turn slid the face far enough between frames (~5 fps)
            // that the smoothed box stopped overlapping, the lock dropped, and no
            // targets were sent for up to 10 s.
            // Floored at a fifth of the frame: session 3 kept dropping the lock
            // with exactly one face in 94 of 98 frames, most likely because a
            // face a few metres away is under 0.1 wide and 1.2 widths of it is
            // less than the face moves between frames while the head turns.
            let gate = max(1.2 * previous.rect.width, 0.2)
            // Ranked by distance from where the face was heading, plus a
            // penalty for a very different size: someone crossing in front or
            // behind is rarely the same size. Both are zero for a still face of
            // steady size, so two equal faces either side stay ambiguous.
            let dt = lastSeen.isFinite ? min(max(now - lastSeen, 0), 1) : 0
            let base = lastCentre ?? CGPoint(x: previous.rect.midX, y: previous.rect.midY)
            let predicted = CGPoint(x: base.x + velocity.dx * dt, y: base.y + velocity.dy * dt)
            let near = valid
                .map { box -> (box: FaceBox, distance: CGFloat, score: CGFloat) in
                    let actual = centreDistance(previous.rect, box.rect)
                    let ahead = hypot(box.rect.midX - predicted.x, box.rect.midY - predicted.y)
                    let sizeChange = abs(box.rect.width - previous.rect.width) / max(previous.rect.width, 0.01)
                    return (box, min(actual, ahead), ahead + 0.3 * sizeChange)
                }
                .filter { overlap(previous.rect, $0.box.rect) >= 0.2 || $0.distance <= gate }
                .sorted { $0.score < $1.score }
            // Two faces near the selection are ambiguous unless one is clearly
            // the better match; ambiguity is never permission to switch people.
            let unambiguous = near.count == 1 || (near.count > 1 && near[1].score >= 2 * near[0].score + 0.02)
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
            if dt > 0, let lastCentre {
                let sample = CGVector(dx: (new.midX - lastCentre.x) / dt, dy: (new.midY - lastCentre.y) / dt)
                velocity = CGVector(dx: velocity.dx + 0.6 * (sample.dx - velocity.dx),
                                    dy: velocity.dy + 0.6 * (sample.dy - velocity.dy))
            }
            lastCentre = CGPoint(x: new.midX, y: new.midY)
            candidate = FaceBox(id: previous.id, rect: smooth, confidence: match.confidence,
                                pose: match.pose, frameWidth: match.frameWidth)
            hits += 1
        } else {
            // A person who was just lost and is back near where they left is
            // preferred over anyone else, even someone larger.
            if let lost = lastLost, now - lost.at <= Self.rememberLostFor {
                let gate = max(1.2 * lost.width, 0.2)
                if let returning = valid
                    .map({ (box: $0, distance: hypot($0.rect.midX - lost.centre.x, $0.rect.midY - lost.centre.y)) })
                    .filter({ $0.distance <= gate })
                    .min(by: { $0.distance < $1.distance }) {
                    candidate = returning.box
                    lastCentre = CGPoint(x: returning.box.rect.midX, y: returning.box.rect.midY)
                    hits = 1
                    lastSeen = now
                    state = .acquiring
                    box = nil
                    return
                }
            }
            // Otherwise deterministic: largest, then closest to center.
            candidate = valid.sorted {
                let a = $0.rect.width * $0.rect.height, b = $1.rect.width * $1.rect.height
                if a != b { return a > b }
                return abs($0.rect.midX - 0.5) < abs($1.rect.midX - 0.5)
            }.first
            guard candidate != nil else { state = .searching; return }
            hits = 1
            lastCentre = candidate.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
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
