import SwiftUI

/// Stanbot asleep: a slow string of z's drifting up where the picture was,
/// as from a sleeper in a comic — but no bubble, and nothing quick. One z at a
/// time is born low and small, rises over several seconds while it grows a
/// little and leans to one side, and fades before the next has got far. Dim
/// grey, the eyes' colour. Calm enough to sit in the corner of the eye all
/// afternoon. Reduce Motion: three still z's, faint.
///
/// Every z is a pure function of its age, drawn from a slow clock (6 frames a
/// second is plenty for something this gentle). Started from `onAppear` with
/// `withAnimation` instead, the first z jumped straight to its end state and
/// nothing ever showed; as Core Animation-style property animations it cost
/// more than the clock, since SwiftUI on the Mac re-renders those every frame
/// (14% against 6%, 2026-09-17).
struct SleepingZs: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var zs: [FloatingZ] = []
    @State private var born = 0

    /// A new z every so often; each lives about this long.
    static let interval: Duration = .seconds(2.8)
    static let life = 5.2

    struct FloatingZ: Identifiable {
        let id: Int
        let birth: Date
        /// Where it starts, as a fraction of the width from the centre.
        let startX: Double
        let lean: Double

        /// 0 just born ... 1 gone: position, size and fade all follow this.
        func progress(at now: Date) -> Double {
            (now.timeIntervalSince(birth) / SleepingZs.life).clamped()
        }
    }

    /// Faint quickly, then a long slow fade: seen, then let go of.
    static func opacity(at progress: Double) -> Double {
        progress < 0.15 ? progress / 0.15 : max(0, 1 - (progress - 0.15) / 0.85)
    }

    var body: some View {
        GeometryReader { proxy in
            let base = min(proxy.size.width, proxy.size.height)
            if reduceMotion {
                // Still: three z's climbing away, the smallest first.
                ForEach(0..<3, id: \.self) { index in
                    Text("z")
                        .font(.system(size: base * (0.05 + 0.015 * Double(index)), weight: .semibold, design: .rounded))
                        .foregroundStyle(Color(white: 0.74).opacity(0.35 - 0.08 * Double(index)))
                        .position(x: proxy.size.width * (0.55 + 0.06 * Double(index)),
                                  y: proxy.size.height * (0.6 - 0.14 * Double(index)))
                }
            } else {
                TimelineView(.periodic(from: .now, by: 1.0 / 6)) { timeline in
                    ForEach(zs) { z in
                        let rise = z.progress(at: timeline.date)
                        Text("z")
                            .font(.system(size: base * (0.045 + 0.035 * rise), weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(white: 0.74))
                            .opacity(0.42 * Self.opacity(at: rise))
                            .rotationEffect(.degrees(z.lean * 14 * rise))
                            .position(x: proxy.size.width * (0.56 + z.startX + 0.07 * z.lean * rise),
                                      y: proxy.size.height * (0.62 - 0.36 * rise))
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Stanbot is asleep")
        .task {
            guard !reduceMotion else { return }
            // Born on a gentle, slightly uneven rhythm, as breathing is.
            while !Task.isCancelled {
                born += 1
                zs.append(FloatingZ(id: born, birth: Date(), startX: Double.random(in: -0.06...0.06),
                                    lean: Double.random(in: -1...1)))
                zs.removeAll { $0.progress(at: Date()) >= 1 }
                try? await Task.sleep(for: Self.interval + .milliseconds(Int.random(in: -300...300)))
            }
        }
    }
}
