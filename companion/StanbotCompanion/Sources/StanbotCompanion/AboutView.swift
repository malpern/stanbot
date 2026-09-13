import AppKit
import SwiftUI

@MainActor
final class StanbotAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also set the live icon so Dock / app switcher do not retain the old
        // generic executable icon while Launch Services refreshes its cache.
        if let icon = AppIdentity.icon {
            NSApplication.shared.applicationIconImage = icon
        }
    }
}

enum AppIdentity {
    static var icon: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    static var version: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "Version \(version) (\(build))"
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                if let icon = AppIdentity.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 144, height: 144)
                        .accessibilityHidden(true)
                }
                Text("Stanbot")
                    .font(.system(size: 28, weight: .bold))
                Text(AppIdentity.version)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("A little robot. A local companion.")
                .font(.headline)
            Text("Connect with StackChan from your Mac.\nView its camera, see detected faces, and explore its expressions.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Label("Camera processing stays on your Mac", systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)

            Divider()
            HStack(spacing: 24) {
                Link("Project", destination: URL(string: "https://github.com/malpern/stanbot")!)
                Link("StackChan", destination: URL(string: "https://docs.m5stack.com/en/StackChan")!)
            }
            .font(.callout)
            Text("Made for Micah’s StackChan\nIndependent companion · not an M5Stack product")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(width: 400)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
