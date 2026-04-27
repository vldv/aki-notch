//
//  NotchPanelController.swift
//  aki-notch-ui
//

import AppKit
import SwiftUI
import os

/// Borderless NSPanel that can become key when needed (for chat text input).
private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private let panelLogger = Logger(subsystem: "com.akinotch.app", category: "Panel")

final class NotchPanelController {
    private let panel: NSPanel
    private var interactionGeneration: Int = 0
    var isInteractionEnabled: Bool { !panel.ignoresMouseEvents }

    init(viewModel: NotchOverlayViewModel, settings: OverlaySettings) {
        let contentRect = NSRect(
            x: 0, y: 0,
            width: OverlayMetrics.panelWidth,
            height: OverlayMetrics.panelHeight
        )

        panel = KeyablePanel(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        let container = NSView(frame: contentRect)
        container.autoresizesSubviews = true

        let hostingView = NSHostingView(
            rootView: ContentView(viewModel: viewModel, settings: settings)
        )
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)

        panel.contentView = container
        updateFrame()
    }

    func show() {
        updateFrame()
        panel.orderFrontRegardless()
    }

    func enableInteraction(smallMode: Bool = false, contentHeight: CGFloat = 0) {
        panelLogger.info("Panel interaction ENABLED (contentHeight=\(contentHeight))")
        interactionGeneration += 1
        // Shrink the panel to roughly the card size so transparent areas
        // don't capture mouse events from the rest of the screen.
        let scale: CGFloat = smallMode ? 0.515 : 1.0
        let cardWidth = OverlayMetrics.expandedWidth * scale + 80
        // Use measured content height if available, otherwise fall back to full panel.
        let panelHeight = contentHeight > 10 ? contentHeight + 20 : OverlayMetrics.panelHeight
        guard let screen = Self.builtInScreen() ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let sf = screen.frame
        let origin = CGPoint(
            x: sf.midX - cardWidth / 2,
            y: sf.maxY - panelHeight
        )
        panel.setFrame(
            NSRect(
                origin: origin, size: CGSize(width: cardWidth, height: panelHeight)),
            display: true
        )
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }

    /// Narrow the panel to just the minimized strip width so only the
    /// expand-triangle area captures mouse events.
    func enableMinimizedInteraction(
        stripWidth: CGFloat, smallMode: Bool = false, contentHeight: CGFloat = 0
    ) {
        panelLogger.info(
            "Panel interaction ENABLED (minimized strip, contentHeight=\(contentHeight))")
        interactionGeneration += 1
        let scale: CGFloat = smallMode ? 0.515 : 1.0
        let panelWidth = stripWidth * scale + 40
        let panelHeight = contentHeight > 10 ? contentHeight + 20 : OverlayMetrics.panelHeight
        guard let screen = Self.builtInScreen() ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let sf = screen.frame
        let origin = CGPoint(
            x: sf.midX - panelWidth / 2,
            y: sf.maxY - panelHeight
        )
        panel.setFrame(
            NSRect(
                origin: origin,
                size: CGSize(width: panelWidth, height: panelHeight)),
            display: true
        )
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }

    func disableInteraction() {
        panelLogger.info("Panel interaction DISABLED")
        panel.ignoresMouseEvents = true
        // Delay frame restoration until the dismiss animation finishes
        // so the card doesn't visually jump.
        let generation = interactionGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self, self.interactionGeneration == generation else { return }
            self.updateFrame()
        }
    }

    func updateFrame() {
        guard let screen = Self.builtInScreen() ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let frame = screen.frame
        let origin = CGPoint(
            x: frame.midX - (OverlayMetrics.panelWidth / 2),
            y: frame.maxY - OverlayMetrics.panelHeight
        )
        panel.setFrame(
            NSRect(
                origin: origin,
                size: CGSize(width: OverlayMetrics.panelWidth, height: OverlayMetrics.panelHeight)),
            display: true
        )
    }

    /// Prefer the built-in display (the one with the notch) over any external monitor.
    private static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            guard let screenNumber = screen.deviceDescription[key] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(screenNumber) != 0
        }
    }
}
