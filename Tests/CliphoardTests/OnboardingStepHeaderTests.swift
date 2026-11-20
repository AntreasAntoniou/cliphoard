import AppKit
import SwiftUI
import XCTest
@testable import Cliphoard

@MainActor
final class OnboardingStepHeaderTests: XCTestCase {
    func testWelcomeArtworkAndProgressHeaderFitInBothAppearances() throws {
        _ = NSApplication.shared
        let resources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let output = ProcessInfo.processInfo.environment["CLIPHOARD_ONBOARDING_UI_SNAPSHOTS"]
        for scheme: ColorScheme in [.light, .dark] {
            let art = try XCTUnwrap(BrandIcon.load(for: scheme, resourceDirectory: resources))
            for step in GuidedSetupDraft.Step.allCases {
                let view = OnboardingStepHeader(step: step, clipMoment: step.rawValue, brandImage: art)
                    .frame(width: 600)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                    .preferredColorScheme(scheme)
                let host = NSHostingView(rootView: view)
                let height = ceil(host.fittingSize.height)
                let welcome = step == .welcome
                XCTAssertTrue((welcome ? 270...350 : 95...120).contains(height), "\(step): \(height)")
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: height),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = CGRect(x: 0, y: 0, width: 600, height: height)
                host.layoutSubtreeIfNeeded()
                XCTAssertFalse(window.isVisible)
                if let output, [.welcome, .tags, .finish].contains(step) {
                    let directory = URL(fileURLWithPath: output, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    let theme = scheme == .dark ? "dark" : "light"
                    try png.write(to: directory.appendingPathComponent("onboarding-\(step)-\(theme).png"),
                                  options: .withoutOverwriting)
                }
                window.close()
            }
        }
    }
}
