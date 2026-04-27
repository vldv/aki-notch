//
//  OverlayModels.swift
//  aki-notch-ui
//

import AppKit
import Foundation
import SwiftUI

// MARK: - Metrics

enum OverlayMetrics {
    static let expandedWidth: CGFloat = 660
    static let composeWidth: CGFloat = 360
    static let imageFixedHeight: CGFloat = 180
    static let panelWidth: CGFloat = 1000
    static let panelHeight: CGFloat = 850
}

// MARK: - Models

struct OverlayCard: Identifiable {
    let id = UUID()
    let name: String
    let nameColor: Color
    let message: String
    let imageURL: URL?
    let image: NSImage?
    /// Raw image data for animated image support (GIF/WebP).
    let imageData: Data?
    let accentColor: Color
    /// Horizontal position of the portrait within the card (0.0 = left, 0.5 = center, 1.0 = right).
    var imagePosition: CGFloat = 0.5
}

struct OverlayAPIRequest: Decodable {
    var title: String?
    var name: String?
    var nameColor: String?
    var message: String
    var imageURL: String?
    var imageBase64: String?
    var accentHex: String?
    var expanded: Bool?
    var character: String?
    var face: String?
}

struct ChatAPIRequest: Decodable {
    var title: String?
    var name: String?
    var nameColor: String?
    var message: String
    var imageURL: String?
    var imageBase64: String?
    var accentHex: String?
    var proposedAnswers: [String]?
    var character: String?
    var face: String?
}

// MARK: - Color Helpers

extension Color {
    init(hex: String) {
        let cleaned =
            hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)

        let red: Double
        let green: Double
        let blue: Double

        switch cleaned.count {
        case 6:
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        default:
            red = 0.5
            green = 0.84
            blue = 1.0
        }

        self.init(.sRGB, red: red, green: green, blue: blue, opacity: 1)
    }

    var hexString: String {
        let nsColor = NSColor(self)
        guard let rgb = nsColor.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
