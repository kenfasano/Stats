//
//  VisualEffectView.swift
//  Stats
//
//  Created by Ken Fasano on 1/26/26.
//

import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow    // Use .withinWindow if you want it contained in a frame
        view.state = .active
        view.material = .underWindowBackground // The standard macOS translucent look
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
