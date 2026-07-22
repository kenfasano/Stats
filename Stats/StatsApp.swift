//
//  StatsApp.swift
//  Stats
//
//  Created by Ken Fasano on 1/15/26.
//

import SwiftUI
import AppKit

@main
struct SystemStatusApp: App {
    // Width stays ~2/3 of a 1920-wide screen; height spans from just under the menu bar
    // (even when auto-hidden) down to the bottom of the screen.
    private static var contentSize: CGSize {
        guard let screen = NSScreen.main else { return CGSize(width: 1280, height: 950) }
        let menuBarGap = max(screen.frame.height - screen.visibleFrame.height, 24)
        let titleBarChrome: CGFloat = 32 // hidden-title-bar window chrome not covered by our content frame
        let outerHeight = screen.frame.height - menuBarGap
        return CGSize(width: 1280, height: outerHeight - titleBarChrome)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: Self.contentSize.width, height: Self.contentSize.height)
                // This puts the "Frosted Glass" effect behind your app
                .background(VisualEffectView().ignoresSafeArea())
                .onAppear {
                    DispatchQueue.main.async { Self.positionWindowAtScreenBottom() }
                }
        }
        // This removes the standard opaque window bar
        .windowStyle(.hiddenTitleBar)
        // This ensures the background is transparent
        .windowResizability(.contentSize)
    }

    private static func positionWindowAtScreenBottom() {
        guard let window = NSApp.windows.first else { return }
        // Use whichever screen the window actually landed on, not necessarily the Main Display.
        guard let screen = window.screen ?? NSScreen.main else { return }
        let x = screen.frame.minX + (screen.frame.width - window.frame.width) / 2
        let y = screen.frame.minY
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
