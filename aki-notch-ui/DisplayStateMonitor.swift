import AppKit
import os

// MARK: - Notification Name

extension Notification.Name {
    static let displayConfigurationChanged = Notification.Name("com.akinotch.displayConfigChanged")
}

// MARK: - DisplayStateMonitor

/// Stateless utility that detects whether the MacBook lid is closed (clamshell mode).
///
/// Call `setup()` once at app startup. After that, use `isLidClosed()` at any time
/// to decide whether to suppress notch-area notifications.
enum DisplayStateMonitor {

    // MARK: - Private State

    private static let logger = Logger(subsystem: "com.akinotch.app", category: "DisplayState")

    /// Whether this Mac has a built-in (laptop) display. Set once during `setup()`.
    private static var hasBuiltInDisplay = false

    /// Guard against double-initialization.
    private static var initialized = false

    // MARK: - Setup

    /// Call once at app startup.
    ///
    /// - Scans online displays (includes inactive ones) to determine whether a
    ///   built-in display exists on this machine.
    /// - Registers a Core Graphics reconfiguration callback that posts
    ///   `.displayConfigurationChanged` whenever the display layout changes.
    static func setup() {
        guard !initialized else {
            logger.warning("setup() called more than once — ignoring.")
            return
        }
        initialized = true

        // --- Detect built-in display ----------------------------------------
        // `CGGetOnlineDisplayList` returns displays that are online, which
        // includes built-in displays even when the lid is closed.
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
        var displayCount: UInt32 = 0

        let result = CGGetOnlineDisplayList(UInt32(onlineDisplays.count),
                                            &onlineDisplays,
                                            &displayCount)

        if result == .success {
            let displays = Array(onlineDisplays.prefix(Int(displayCount)))
            hasBuiltInDisplay = displays.contains { CGDisplayIsBuiltin($0) != 0 }
        } else {
            logger.error("CGGetOnlineDisplayList failed with error \(result.rawValue)")
            hasBuiltInDisplay = false
        }

        logger.info(
            "Initialized — hasBuiltInDisplay: \(hasBuiltInDisplay), isLidClosed: \(isLidClosed())"
        )

        // --- Register reconfiguration callback ------------------------------
        CGDisplayRegisterReconfigurationCallback({ _, flags, _ in
            // Only fire on the "end" event, not the "begin".
            guard flags.contains(.beginConfigurationFlag) == false else { return }

            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .displayConfigurationChanged, object: nil)
            }
        }, nil)
    }

    // MARK: - Query

    /// Returns `true` when the built-in display's lid is closed (clamshell mode).
    ///
    /// - On a desktop Mac (no built-in display) this always returns `false`.
    /// - On a laptop it checks whether the built-in display is absent from `NSScreen.screens`.
    static func isLidClosed() -> Bool {
        guard hasBuiltInDisplay else { return false }

        let builtInScreenExists = NSScreen.screens.contains { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? CGDirectDisplayID else {
                return false
            }
            return CGDisplayIsBuiltin(screenNumber) != 0
        }

        return !builtInScreenExists
    }
}
