// AnimatedImageView.swift — aki-notch-ui
//
// Renders animated images (GIF, animated WebP, APNG) in SwiftUI via CGImageSource
// frame extraction + timer-driven animation. NSImageView.animates only works for GIF;
// this approach handles all formats that ImageIO can decode (including animated WebP on macOS 14+).

import AppKit
import ImageIO
import SwiftUI

// MARK: - SwiftUI Bridge

struct AnimatedImageView: NSViewRepresentable {
    let data: Data

    func makeNSView(context: Context) -> AnimatedImageNSView {
        let view = AnimatedImageNSView()
        view.loadData(data)
        return view
    }

    func updateNSView(_ nsView: AnimatedImageNSView, context: Context) {
        if nsView.currentData != data {
            nsView.loadData(data)
        }
    }
}

// MARK: - AppKit Animation View

final class AnimatedImageNSView: NSView {
    private(set) var currentData: Data?
    private var displayTimer: Timer?
    private var frames: [(image: CGImage, duration: TimeInterval)] = []
    private var currentFrameIndex = 0
    private let imageLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        imageLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    func loadData(_ data: Data) {
        stopAnimation()
        currentData = data
        frames = Self.extractFrames(from: data)
        currentFrameIndex = 0

        if frames.isEmpty {
            if let nsImage = NSImage(data: data),
               let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            {
                setLayerContents(cgImage)
            }
            return
        }

        setLayerContents(frames[0].image)

        if frames.count > 1 {
            scheduleNextFrame()
        }
    }

    // MARK: Animation Loop

    private func scheduleNextFrame() {
        let delay = frames[currentFrameIndex].duration
        let timer = Timer(timeInterval: delay, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            self.currentFrameIndex = (self.currentFrameIndex + 1) % self.frames.count
            self.setLayerContents(self.frames[self.currentFrameIndex].image)
            self.scheduleNextFrame()
        }
        // Use .common mode so the timer fires even during window interaction
        // (scrolling, resizing, modal sheets). The default mode pauses timers
        // when the run loop enters .eventTracking mode.
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopAnimation() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    private func setLayerContents(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    deinit {
        stopAnimation()
    }

    // MARK: Frame Extraction

    static func extractFrames(from data: Data) -> [(image: CGImage, duration: TimeInterval)] {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return [] }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return [] }

        var result: [(CGImage, TimeInterval)] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            let duration = Self.frameDuration(at: i, source: source)
            result.append((cgImage, duration))
        }
        return result
    }

    private static func frameDuration(at index: Int, source: CGImageSource) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as? [CFString: Any]
        else {
            return 0.1
        }

        // --- GIF ---
        if let gifDict = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
            if let delay = gifDict[kCGImagePropertyGIFUnclampedDelayTime] as? Double, delay > 0.001 {
                return delay
            }
            if let delay = gifDict[kCGImagePropertyGIFDelayTime] as? Double, delay > 0.001 {
                return delay
            }
        }

        // --- WebP (macOS 14+) ---
        let webPKey = "{WebP}" as CFString
        if let webpDict = properties[webPKey] as? [String: Any] {
            if let delay = webpDict["UnclampedDelayTime"] as? Double, delay > 0.001 {
                return delay
            }
            if let delay = webpDict["DelayTime"] as? Double, delay > 0.001 {
                return delay
            }
        }

        // --- APNG ---
        if let pngDict = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any] {
            if let delay = pngDict[kCGImagePropertyAPNGUnclampedDelayTime] as? Double, delay > 0.001 {
                return delay
            }
            if let delay = pngDict[kCGImagePropertyAPNGDelayTime] as? Double, delay > 0.001 {
                return delay
            }
        }

        return 0.1
    }
}

// MARK: - Detection Helper

func isAnimatedImageData(_ data: Data) -> Bool {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
    return CGImageSourceGetCount(source) > 1
}
