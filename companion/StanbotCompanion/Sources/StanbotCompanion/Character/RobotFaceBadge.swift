import AppKit
import SwiftUI

/// The front of Stanbot's CoreS3 head, at any width: a light grey rim around
/// black glass, the 4:3 screen with the same live eyes and mouth the robot
/// draws, and the copper camera ring below it, as on the real StackChan
/// (docs/app-design.md). Proportions are from the 38 pt title-bar version.
struct RobotFace: View {
    var mood: Mood
    var width: CGFloat
    var reaction: EyeReaction? = nil
    /// Large faces: the LCD grid, the mouth's glow, and eyes that follow the
    /// pointer. Off for the title bar, where they only blur.
    var detailed = false
    /// What a click on the face does. Nothing passed: the eyes giggle.
    var onTap: (() -> Void)? = nil

    static let aspect: CGFloat = 36.0 / 38.0

    var body: some View {
        let s = width / 38
        let rim = 1.5 * s
        let screenWidth = width - 2 * rim - 5 * s
        let screenHeight = screenWidth * 3 / 4
        // Wrapped in a ZStack: a toolbar item must not be a bare shape or image.
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7 * s, style: .continuous)
                .fill(Color(white: 0.86))
            RoundedRectangle(cornerRadius: 5.5 * s, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.02)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(rim)
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 1.5 * s, style: .continuous)
                        .fill(Color(white: 0.09))
                    StanbotEyesView(emotion: mood.emotion, look: mood.look, asleep: mood.asleep, screen: false,
                                    scanning: mood.scanning, reaction: reaction, interactive: detailed,
                                    screenLook: detailed, engaged: mood.engaged, closeness: mood.closeness,
                                    onTap: onTap, mouthMinimumPoints: detailed ? 0 : 1.2, mouthGlow: detailed)
                }
                .frame(width: screenWidth, height: screenHeight)
                .padding(.top, rim + 2.5 * s)
                Spacer(minLength: 0)
                // The camera, a copper ring centred under the screen.
                Circle()
                    .strokeBorder(Color(red: 0.78, green: 0.42, blue: 0.22), lineWidth: 0.8 * s)
                    .frame(width: 3.4 * s, height: 3.4 * s)
                    .padding(.bottom, rim + 2.2 * s)
            }
        }
        .frame(width: width, height: width * Self.aspect)
        .accessibilityElement()
        .accessibilityLabel("Stanbot, \(mood.caption.lowercased())")
    }
}

/// The whole title bar's left side: Stanbot's live eyes and mouth, its name,
/// and the red dot when it cannot be reached — the only connection signal; a
/// working link shows nothing (the link is in Diagnostics and Details).
/// The window's own title is hidden so the dot can sit right of the name.
/// Connection details are in Diagnostics; hovering the dot says what is wrong.
struct RobotFaceBadge: View {
    @EnvironmentObject private var robot: RobotConnection
    var mood: Mood

    static let size = CGSize(width: 130, height: 26)

    var body: some View {
        HStack(spacing: 6) {
            StanbotEyesView(emotion: mood.emotion, look: mood.look, asleep: mood.asleep, screen: false,
                            scanning: mood.scanning, engaged: mood.engaged,
                            mouthMinimumPoints: 1.2, mouthGlow: false)
                .frame(width: 34, height: 26)
                .help(mood.caption)
            Text("Stanbot")
                .font(.headline)
            ReachabilityDot()
            Spacer(minLength: 0)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Stanbot, \(mood.caption.lowercased()), \(robot.linkSummary)")
    }

}

/// Puts a SwiftUI view in the window's title bar, left of the title, as a
/// titlebar accessory, and keeps it updated as `content` changes. SwiftUI's
/// .navigation toolbar placement drew nothing in this window (2026-09-17).
struct TitlebarFace<Content: View>: NSViewRepresentable {
    var content: Content

    final class Coordinator {
        var host: NSHostingView<Content>?
        var accessory: NSTitlebarAccessoryViewController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { attach(to: view.window, context.coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if let host = context.coordinator.host {
            host.rootView = content
        } else {
            DispatchQueue.main.async { attach(to: view.window, context.coordinator) }
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        guard let accessory = coordinator.accessory, let window = accessory.view.window,
              let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) else { return }
        window.removeTitlebarAccessoryViewController(at: index)
    }

    private func attach(to window: NSWindow?, _ coordinator: Coordinator) {
        guard let window, coordinator.host == nil else { return }
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: RobotFaceBadge.size.width + 12, height: RobotFaceBadge.size.height)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = host
        accessory.layoutAttribute = .leading
        window.addTitlebarAccessoryViewController(accessory)
        coordinator.host = host
        coordinator.accessory = accessory
    }
}
