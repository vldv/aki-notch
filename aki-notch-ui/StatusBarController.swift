// StatusBarController.swift — aki-notch-ui

import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()

    // Keep weak refs to these so we can read state for menu rebuilds
    weak var settings: OverlaySettings?
    weak var licenseManager: LicenseManager?

    // Action closures (set by AppDelegate)
    var onOpenSettings: (() -> Void)?
    var onCompose: (() -> Void)?
    var onTestPayload: (() -> Void)?
    var onTestChat: (() -> Void)?
    var onTestConversation: (() -> Void)?
    var onToggleSmallMode: (() -> Void)?
    var onToggleDockIcon: (() -> Void)?
    var onToggleStatusBar: (() -> Void)?
    var onCheckForUpdates: (() -> Void)?
    var onActivateLicense: (() -> Void)?
    var isUpdaterAvailable = false
    var isTestConversationEnabled: (() -> Bool)?

    func setup() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Use custom Aki icon from asset catalog
        if let button = statusItem?.button {
            let image = NSImage(named: "StatusBarIcon")
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
            button.image?.isTemplate = false  // keep original colors
        }

        menu.delegate = self
        statusItem?.menu = menu
    }

    func show() {
        if statusItem == nil { setup() }
        statusItem?.isVisible = true
    }

    func hide() {
        statusItem?.isVisible = false
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let settingsItem = NSMenuItem(
            title: "Aki Notch Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(
            title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        updateItem.isEnabled = isUpdaterAvailable
        menu.addItem(updateItem)

        // License status
        if let lm = licenseManager {
            let licenseTitle: String
            switch lm.status {
            case .trial(let days):
                licenseTitle = "Trial — \(days) day\(days == 1 ? "" : "s") left"
            case .active:
                licenseTitle = "✓ Licensed"
            case .expired:
                licenseTitle = "⚠ Trial Expired"
            case .invalid:
                licenseTitle = "⚠ Invalid License"
            }
            let licenseItem = NSMenuItem(
                title: licenseTitle, action: #selector(activateLicense), keyEquivalent: "")
            licenseItem.target = self
            menu.addItem(licenseItem)
        }

        menu.addItem(.separator())

        let composeItem = NSMenuItem(
            title: "Compose", action: #selector(compose), keyEquivalent: "")
        composeItem.target = self
        menu.addItem(composeItem)

        menu.addItem(.separator())

        let testItem = NSMenuItem(
            title: "Test Payload", action: #selector(testPayload), keyEquivalent: "")
        testItem.target = self
        menu.addItem(testItem)

        let testChatItem = NSMenuItem(
            title: "Test Chat", action: #selector(testChat), keyEquivalent: "")
        testChatItem.target = self
        menu.addItem(testChatItem)

        let testConvoItem = NSMenuItem(
            title: "Test Conversation", action: #selector(testConversation), keyEquivalent: "")
        testConvoItem.target = self
        testConvoItem.isEnabled = isTestConversationEnabled?() ?? false
        menu.addItem(testConvoItem)

        menu.addItem(.separator())

        let smallItem = NSMenuItem(
            title: "Small Mode", action: #selector(toggleSmallMode), keyEquivalent: "")
        smallItem.target = self
        smallItem.state = (settings?.smallMode ?? false) ? .on : .off
        menu.addItem(smallItem)

        menu.addItem(.separator())

        let dockItem = NSMenuItem(
            title: "Show in Dock", action: #selector(toggleDock), keyEquivalent: "")
        dockItem.target = self
        dockItem.state = (settings?.showDockIcon ?? true) ? .on : .off
        menu.addItem(dockItem)

        let statusBarItem = NSMenuItem(
            title: "Show in Menu Bar", action: #selector(toggleStatusBarIcon), keyEquivalent: "")
        statusBarItem.target = self
        statusBarItem.state = (settings?.showStatusBarIcon ?? true) ? .on : .off
        menu.addItem(statusBarItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Aki Notch", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    // MARK: - Actions

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func checkForUpdates() { onCheckForUpdates?() }
    @objc private func activateLicense() { onActivateLicense?() }
    @objc private func compose() { onCompose?() }
    @objc private func testPayload() { onTestPayload?() }
    @objc private func testChat() { onTestChat?() }
    @objc private func testConversation() { onTestConversation?() }
    @objc private func toggleSmallMode() { onToggleSmallMode?() }
    @objc private func toggleDock() { onToggleDockIcon?() }
    @objc private func toggleStatusBarIcon() { onToggleStatusBar?() }
}
