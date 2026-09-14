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

    mutating func reset() { self = Self() }

    mutating func expire(at now: TimeInterval) {
        if now - lastSeen >= 0.9 { reset() }
        else if now - lastSeen >= 0.45, state == .tracking {
            state = .uncertain
            box = nil
        }
    }

    mutating func update(_ observations: [FaceBox], at now: TimeInterval) {
        guard now > lastUpdate else { return }
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
            let matches = valid.filter { overlap(previous.rect, $0.rect) >= 0.2 }
            // Ambiguity is not permission to switch to a different person.
            guard matches.count == 1, let match = matches.first else {
                box = nil
                if hits >= 3 { state = .uncertain }
                else { reset() }
                return
            }
            let alpha = 0.65
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

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let intersection = a.intersection(b)
        guard !intersection.isNull else { return 0 }
        let area = intersection.width * intersection.height
        return area / (a.width * a.height + b.width * b.height - area)
    }
}
