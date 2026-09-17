import AppKit
import SwiftUI

/// Stanbot in the title bar, left of its name: the front of the robot's CoreS3
/// head at toolbar size. A light grey rim around black glass, the screen with
/// the same live eyes and mouth the robot draws, and the copper camera ring
/// below it, as on the real StackChan (docs/app-design.md). Too small for the
/// whole robot, so it is the face only.
struct RobotFaceBadge: View {
    var mood: Mood

    /// The CoreS3 front is square; the screen is 4:3 in its upper part.
    static let size = CGSize(width: 38, height: 36)

    var body: some View {
        let rim: CGFloat = 1.5
        let glassWidth = Self.size.width - 2 * rim
        let screenWidth = glassWidth - 5
        let screenHeight = screenWidth * 3 / 4
        // Wrapped in a ZStack: a toolbar item must not be a bare shape or image.
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(white: 0.86))
            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.13), Color(white: 0.02)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(rim)
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Color(white: 0.09))
                    StanbotEyesView(emotion: mood.emotion, look: mood.look, asleep: mood.asleep, screen: false,
                                    scanning: mood.scanning, engaged: mood.engaged,
                                    mouthMinimumPoints: 1.2, mouthGlow: false)
                }
                .frame(width: screenWidth, height: screenHeight)
                .padding(.top, rim + 2.5)
                Spacer(minLength: 0)
                // The camera, a copper ring centred under the screen.
                Circle()
                    .strokeBorder(Color(red: 0.78, green: 0.42, blue: 0.22), lineWidth: 0.8)
                    .frame(width: 3.4, height: 3.4)
                    .padding(.bottom, rim + 2.2)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .help(mood.caption)
        .accessibilityElement()
        .accessibilityLabel("Stanbot, \(mood.caption.lowercased())")
    }
}

/// Puts a SwiftUI view in the window's title bar, left of the title, as a
/// titlebar accessory, and keeps it updated as `content` changes.
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
