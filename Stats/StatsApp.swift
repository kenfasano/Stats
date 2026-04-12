//
//  StatsApp.swift
//  Stats
//
//  Created by Ken Fasano on 1/15/26.
//

import SwiftUI

@main
struct SystemStatusApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 980, height: 980)  // tune to taste
                // This puts the "Frosted Glass" effect behind your app
                .background(VisualEffectView().ignoresSafeArea())
        }
        // This removes the standard opaque window bar
        .windowStyle(.hiddenTitleBar)
        // This ensures the background is transparent
        .windowResizability(.contentSize)
    }
}

