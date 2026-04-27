//
//  ContentView.swift
//  aki-notch-ui
//
//  Created by Victor on 26/03/2026.
//

import AppKit
import SwiftUI

// MARK: - Image Paste Monitor

/// Installs a local NSEvent monitor that intercepts ⌘V when the key window
/// is a borderless panel (our overlay).  If the clipboard contains an image,
/// the image data is delivered via `onImage` and the event is consumed so the
/// TextField never sees it.  Text-only pastes pass through normally.
private final class ImagePasteMonitor {
    private var monitor: Any?
    private var onImage: ((Data) -> Void)?

    func install(onImage: @escaping (Data) -> Void) {
        self.onImage = onImage
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let handler = self.onImage else { return event }

            // Only intercept ⌘V
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                event.charactersIgnoringModifiers == "v"
            else { return event }

            // Scope to our borderless overlay panel
            guard let win = event.window, win.styleMask.contains(.borderless) else { return event }

            let pb = NSPasteboard.general
            for type in [NSPasteboard.PasteboardType.tiff, .png] {
                if let data = pb.data(forType: type) {
                    if type == .tiff {
                        if let bmp = NSBitmapImageRep(data: data),
                            let png = bmp.representation(using: .png, properties: [:])
                        {
                            handler(png)
                            return nil  // consume
                        }
                    } else {
                        handler(data)
                        return nil  // consume
                    }
                }
            }
            return event  // no image — normal text paste
        }
    }

    func uninstall() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        onImage = nil
    }

    deinit { uninstall() }
}

// MARK: - Card Height Measurement

/// PreferenceKey that reports the rendered height of the active card
/// so the panel can be sized to match (no excess mouse capture).
private struct CardHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Notch Dropdown Shape (flat top, rounded bottom)

struct NotchDropdownShape: InsettableShape {
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let cr = max(cornerRadius - insetAmount, 0)
        var path = Path()
        path.move(to: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - cr))
        path.addArc(
            center: CGPoint(x: r.maxX - cr, y: r.maxY - cr),
            radius: cr,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: r.minX + cr, y: r.maxY))
        path.addArc(
            center: CGPoint(x: r.minX + cr, y: r.maxY - cr),
            radius: cr,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> NotchDropdownShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

/// Border-only shape: left side + bottom (with rounded corners) + right side.
/// No top edge, so it blends seamlessly behind the notch.
struct NotchBorderShape: Shape {
    var cornerRadius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let cr = max(cornerRadius - insetAmount, 0)
        var path = Path()
        // Start 20pt below the top so side borders stay hidden behind the notch
        let topInset: CGFloat = 20
        path.move(to: CGPoint(x: r.minX, y: r.minY + topInset))
        path.addLine(to: CGPoint(x: r.minX, y: r.maxY - cr))
        path.addArc(
            center: CGPoint(x: r.minX + cr, y: r.maxY - cr),
            radius: cr,
            startAngle: .degrees(180),
            endAngle: .degrees(90),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: r.maxX - cr, y: r.maxY))
        path.addArc(
            center: CGPoint(x: r.maxX - cr, y: r.maxY - cr),
            radius: cr,
            startAngle: .degrees(90),
            endAngle: .degrees(0),
            clockwise: true
        )
        path.addLine(to: CGPoint(x: r.maxX, y: r.minY + topInset))
        return path
    }
}

// MARK: - Shared Card Helpers

/// Pixelation factors used by both NotchCard and ChatNotchCard for the image reveal animation.
private let sharedPixelFactors: [CGFloat] = [0.015, 0.03, 0.06, 0.12, 0.24, 0.48, 1.0]

/// Downsample an image by a given factor for the pixelation reveal effect.
private func downsampleImage(_ image: NSImage, factor: CGFloat) -> NSImage {
    let w = max(2, Int(image.size.width * factor))
    let h = max(2, Int(image.size.height * factor))
    let result = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
        return true
    }
    return result
}

/// Build a styled attributed string with the name prefix colored differently.
private func buildStyledText(
    _ text: String,
    visibleCount: Int,
    namePrefixLength: Int,
    nameColor: Color,
    textColor: Color,
    fontSize: CGFloat
) -> some View {
    let visible = text.prefix(visibleCount)
    var result = AttributedString()

    for (i, char) in visible.enumerated() {
        var attr = AttributedString(String(char))
        if i < namePrefixLength {
            attr.foregroundColor = nameColor
        } else {
            attr.foregroundColor = textColor.opacity(0.88)
        }
        result.append(attr)
    }

    return Text(result)
        .font(.custom("PressStart2P", size: fontSize))
        .lineSpacing(8)
        .fixedSize(horizontal: false, vertical: true)
}

/// Compute the full display text for a card: "NAME : message" or just "message".
private func cardFullText(name: String, message: String) -> String {
    if name.isEmpty { return message }
    return "\(name) : \(message)"
}

/// Number of characters that belong to the "NAME: " prefix.
private func cardNamePrefixLength(_ name: String) -> Int {
    name.isEmpty ? 0 : name.count + 2  // "NAME: "
}

// MARK: - Content View

struct ContentView: View {
    @ObservedObject var viewModel: NotchOverlayViewModel
    @ObservedObject var settings: OverlaySettings

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.clear

                if viewModel.isMinimized {
                    let scale: CGFloat = settings.smallMode ? 0.515 : 1.0
                    MinimizedNotchStrip(
                        viewModel: viewModel,
                        settings: settings,
                        scale: scale
                    )
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: CardHeightKey.self, value: g.size.height * scale)
                        }
                    )
                    .offset(x: settings.horizontalOffset)
                    .transition(.move(edge: .top))
                } else if viewModel.isComposeActive {
                    let scale: CGFloat = settings.smallMode ? 0.515 : 1.0
                    ComposeNotchCard(
                        settings: settings,
                        viewModel: viewModel,
                        scale: scale,
                        characterName: viewModel.composeCharacterName
                    )
                    .frame(width: OverlayMetrics.composeWidth)
                    .scaleEffect(scale, anchor: .top)
                    .frame(
                        width: OverlayMetrics.composeWidth * scale,
                        height: nil,
                        alignment: .top
                    )
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: CardHeightKey.self, value: g.size.height * scale)
                        }
                    )
                    .offset(x: settings.horizontalOffset)
                    .transition(.move(edge: .top))
                } else if viewModel.isGameActive, let gameVM = viewModel.gameViewModel {
                    let scale: CGFloat = settings.smallMode ? 0.515 : 1.0
                    GameNotchCard(
                        gameVM: gameVM,
                        settings: settings,
                        scale: scale
                    )
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: CardHeightKey.self, value: g.size.height * scale)
                        }
                    )
                    .offset(x: settings.horizontalOffset)
                    .transition(.move(edge: .top))
                } else if viewModel.isChatActive, let card = viewModel.chatCard {
                    let scale: CGFloat = settings.smallMode ? 0.515 : 1.0
                    ChatNotchCard(
                        card: card,
                        proposedAnswers: viewModel.chatProposedAnswers,
                        settings: settings,
                        viewModel: viewModel,
                        scale: scale
                    )
                    .background(
                        GeometryReader { g in
                            Color.clear.preference(
                                key: CardHeightKey.self, value: g.size.height * scale)
                        }
                    )
                    .offset(x: settings.horizontalOffset)
                    .transition(.move(edge: .top))
                } else if viewModel.isExpanded, let card = viewModel.currentCard {
                    let scale: CGFloat = settings.smallMode ? 0.515 : 1.0
                    NotchCard(card: card, settings: settings, viewModel: viewModel, scale: scale)
                        .id(card.id)
                        .offset(x: settings.horizontalOffset)
                        .transition(.move(edge: .top))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .onPreferenceChange(CardHeightKey.self) { height in
                viewModel.interactiveCardHeight = height
            }
        }
    }
}

// MARK: - Notch Card

private struct NotchCard: View {
    let card: OverlayCard
    @ObservedObject var settings: OverlaySettings
    let viewModel: NotchOverlayViewModel
    let scale: CGFloat

    // Animation sequencing state
    @State private var cardWidth: CGFloat = OverlaySettings.defaultNotchVisualWidth
    @State private var showImage = false
    @State private var imageOpacity: Double = 0
    @State private var pixelFrameIndex: Int = 0
    @State private var pixelFrames: [NSImage] = []
    @State private var visibleChars: Int = 0
    @State private var revealComplete = false

    private var bgColor: Color { Color(hex: settings.bgColorHex) }
    private var borderColor: Color { Color(hex: settings.borderColorHex) }
    private var textColor: Color { Color(hex: settings.textColorHex) }

    private var hasImage: Bool { card.image != nil || card.imageURL != nil }

    /// Aspect ratio of the image (width / height). Defaults to 1:1 for URL images.
    private var imageAspectRatio: CGFloat {
        if let img = card.image {
            let s = img.size
            return s.height > 0 ? s.width / s.height : 1.0
        }
        return 1.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: settings.notchOffset / scale)

            VStack(alignment: .leading, spacing: 18) {
                if hasImage {
                    imageArea
                        .frame(height: OverlayMetrics.imageFixedHeight)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    borderColor.opacity(showImage ? 0.5 : 0),
                                    lineWidth: 1.2
                                )
                        }
                        .accessibilityHidden(true)
                }

                if visibleChars > 0 {
                    textArea
                }

                // Dismiss button — entire row is tappable
                Button {
                    viewModel.collapse()
                } label: {
                    HStack {
                        Spacer()
                        Text("DISMISS")
                            .font(.custom("PressStart2P", size: scale < 1.0 ? 9 * 1.5 : 9))
                            .foregroundStyle(textColor.opacity(0.35))
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
                .accessibilityHint("Double-tap to close this notification")
                .onHover { hovering in
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 8)
        }
        .frame(width: cardWidth)
        .background {
            NotchDropdownShape(cornerRadius: settings.cornerRadius)
                .fill(bgColor)
        }
        .clipShape(NotchDropdownShape(cornerRadius: settings.cornerRadius))
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(card.name): \(card.message)")
        .scaleEffect(scale, anchor: .top)
        .frame(width: cardWidth * scale, alignment: .top)
        .task { await runSequence() }
    }

    // MARK: Image area

    @ViewBuilder
    private var imageArea: some View {
        if showImage {
            if !pixelFrames.isEmpty {
                if revealComplete, let data = card.imageData, isAnimatedImageData(data) {
                    // After pixelation reveal, switch to animated view for GIF/WebP
                    AnimatedImageView(data: data)
                        .accessibilityHidden(true)
                } else {
                    let idx = min(pixelFrameIndex, pixelFrames.count - 1)
                    Image(nsImage: pixelFrames[idx])
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .opacity(imageOpacity)
                        .accessibilityHidden(true)
                }
            } else if let url = card.imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .opacity(imageOpacity)
                    case .failure:
                        PlaceholderArt()
                    case .empty:
                        PlaceholderArt()
                            .overlay { ProgressView().tint(.white.opacity(0.5)) }
                    @unknown default:
                        PlaceholderArt()
                    }
                }
                .accessibilityHidden(true)
            }
        } else {
            Color.clear
        }
    }

    // MARK: Text area

    /// The current message text — uses streaming message if available, otherwise card's static message.
    private var currentMessage: String {
        viewModel.streamingOverlayMessage ?? card.message
    }

    @ViewBuilder
    private var textArea: some View {
        buildStyledText(
            cardFullText(name: card.name, message: currentMessage),
            visibleCount: visibleChars,
            namePrefixLength: cardNamePrefixLength(card.name),
            nameColor: card.nameColor,
            textColor: textColor,
            fontSize: scale < 1.0 ? 12 * 1.5 : 12
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Animation sequence

    private func runSequence() async {
        // Set initial width to match notch at current scale
        cardWidth = settings.notchVisualWidth / scale

        // Precompute pixelated frames for base64/bundled images
        if let img = card.image {
            pixelFrames = sharedPixelFactors.map { factor in
                factor >= 1.0 ? img : downsampleImage(img, factor: factor)
            }
        }

        // 1) Wait for the narrow drop to fully settle
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        // 2) Expand sideways
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
            cardWidth = OverlayMetrics.expandedWidth
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        // — pause before content appears —
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }

        // 3) Pixelated image reveal — box grows vertically to fit
        if !pixelFrames.isEmpty {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showImage = true
            }
            let stepCount = pixelFrames.count
            for i in 0..<stepCount {
                guard !Task.isCancelled else { return }
                pixelFrameIndex = i
                withAnimation(.linear(duration: 0.07)) {
                    imageOpacity = Double(i + 1) / Double(stepCount)
                }
                try? await Task.sleep(for: .milliseconds(85))
            }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            // Switch to animated image view if this is a GIF/WebP
            revealComplete = true
        } else if card.imageURL != nil {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showImage = true
            }
            withAnimation(.easeIn(duration: 0.4)) {
                imageOpacity = 1
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
        }

        // 4) Typewriter — box grows down as text wraps
        if viewModel.streamingOverlayMessage != nil {
            // ── Streaming mode: type characters as they arrive from the LLM ──
            var typedCount = 0
            var stableCount = 0  // how many polls the length hasn't changed
            var lastLength = 0
            while true {
                guard !Task.isCancelled else { return }
                let msg = viewModel.streamingOverlayMessage

                // nil means cleanup happened (tool finished) — exit immediately
                guard let currentMsg = msg else { break }

                let fullText = cardFullText(name: card.name, message: currentMsg)

                if typedCount < fullText.count {
                    typedCount += 1
                    visibleChars = typedCount
                    stableCount = 0
                    lastLength = fullText.count
                    try? await Task.sleep(for: .milliseconds(Int(settings.textSpeed)))
                } else {
                    // We've typed everything available. Check if message is still growing.
                    if fullText.count == lastLength {
                        stableCount += 1
                    } else {
                        stableCount = 0
                        lastLength = fullText.count
                    }

                    // If the message hasn't grown for ~500ms (17 polls × 30ms),
                    // assume it's final (tool has set the complete message).
                    if stableCount > 16 && fullText.count > 0 {
                        break
                    }

                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
        } else {
            // ── Non-streaming: type the complete text (existing behavior) ──
            let allChars = Array(cardFullText(name: card.name, message: card.message))
            for i in 0..<allChars.count {
                guard !Task.isCancelled else { return }
                visibleChars = i + 1
                try? await Task.sleep(for: .milliseconds(Int(settings.textSpeed)))
            }
        }

        // 5) Sequence is done — NOW start the display-duration countdown.
        guard !Task.isCancelled else { return }
        viewModel.sequenceDidComplete()
    }
}

// MARK: - Chat Notch Card

private struct ChatNotchCard: View {
    let card: OverlayCard
    let proposedAnswers: [String]
    @ObservedObject var settings: OverlaySettings
    let viewModel: NotchOverlayViewModel
    let scale: CGFloat

    @State private var cardWidth: CGFloat = OverlaySettings.defaultNotchVisualWidth
    @State private var showImage = false
    @State private var imageOpacity: Double = 0
    @State private var pixelFrameIndex: Int = 0
    @State private var pixelFrames: [NSImage] = []
    @State private var visibleChars: Int = 0
    @State private var revealComplete = false
    @State private var showInput = false
    @State private var userInput: String = ""
    @State private var pastedImages: [Data] = []
    @FocusState private var isInputFocused: Bool
    @State private var pasteMonitor = ImagePasteMonitor()

    private var bgColor: Color { Color(hex: settings.bgColorHex) }
    private var borderColor: Color { Color(hex: settings.borderColorHex) }
    private var textColor: Color { Color(hex: settings.textColorHex) }

    private var hasImage: Bool { card.image != nil || card.imageURL != nil }

    private var imageAspectRatio: CGFloat {
        if let img = card.image {
            let s = img.size
            return s.height > 0 ? s.width / s.height : 1.0
        }
        return 1.0
    }

    private var fontSize: CGFloat {
        scale < 1.0 ? 12 * 1.5 : 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: settings.notchOffset / scale)

            VStack(alignment: .leading, spacing: 18) {
                if hasImage {
                    imageArea
                        .frame(height: OverlayMetrics.imageFixedHeight)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(
                                    borderColor.opacity(showImage ? 0.5 : 0),
                                    lineWidth: 1.2
                                )
                        }
                        .accessibilityHidden(true)
                }

                if visibleChars > 0 {
                    textArea
                }

                if showInput {
                    inputArea
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                // Minimize + Dismiss row
                ZStack {
                    // Minimize triangle — centered, generous hit target
                    Button {
                        viewModel.toggleMinimize()
                    } label: {
                        Image(systemName: "chevron.compact.up")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(textColor.opacity(0.3))
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Minimize")
                    .accessibilityHint("Double-tap to hide this card behind the notch")

                    // Dismiss — right-aligned, generous hit target
                    HStack {
                        Spacer()
                        Button {
                            viewModel.submitChatAnswer("")
                        } label: {
                            Text("DISMISS")
                                .font(.custom("PressStart2P", size: fontSize * 0.85))
                                .foregroundStyle(textColor.opacity(0.35))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                        .accessibilityHint("Double-tap to close this chat")
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .padding(.top, 8)
        }
        .frame(width: cardWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.name) asks: \(card.message)")
        .background {
            NotchDropdownShape(cornerRadius: settings.cornerRadius)
                .fill(bgColor)
        }
        .clipShape(NotchDropdownShape(cornerRadius: settings.cornerRadius))
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .scaleEffect(scale, anchor: .top)
        .frame(width: cardWidth * scale, alignment: .top)
        .task { await runSequence() }
    }

    // MARK: Image area

    @ViewBuilder
    private var imageArea: some View {
        if showImage {
            if !pixelFrames.isEmpty {
                if revealComplete, let data = card.imageData, isAnimatedImageData(data) {
                    // After pixelation reveal, switch to animated view for GIF/WebP
                    AnimatedImageView(data: data)
                        .accessibilityHidden(true)
                } else {
                    let idx = min(pixelFrameIndex, pixelFrames.count - 1)
                    Image(nsImage: pixelFrames[idx])
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .opacity(imageOpacity)
                        .accessibilityHidden(true)
                }
            } else if let url = card.imageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit()
                            .opacity(imageOpacity)
                    case .failure:
                        PlaceholderArt()
                    case .empty:
                        PlaceholderArt()
                            .overlay { ProgressView().tint(.white.opacity(0.5)) }
                    @unknown default:
                        PlaceholderArt()
                    }
                }
                .accessibilityHidden(true)
            }
        } else {
            Color.clear
        }
    }

    // MARK: Text area

    @ViewBuilder
    private var textArea: some View {
        buildStyledText(
            cardFullText(name: card.name, message: card.message),
            visibleCount: visibleChars,
            namePrefixLength: cardNamePrefixLength(card.name),
            nameColor: card.nameColor,
            textColor: textColor,
            fontSize: fontSize
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Input area

    @ViewBuilder
    private var inputArea: some View {
        if proposedAnswers.isEmpty {
            freeTextInput
        } else {
            VStack(spacing: 14) {
                proposedAnswerButtons
                freeTextInput
            }
        }
    }

    private var freeTextInput: some View {
        HStack(spacing: 10) {
            Text(">")
                .font(.custom("PressStart2P", size: fontSize))
                .foregroundColor(card.accentColor.opacity(0.6))
                .accessibilityHidden(true)

            // Pasted image icons (tap to remove)
            ForEach(Array(pastedImages.enumerated()), id: \.offset) { index, _ in
                Button {
                    pastedImages.remove(at: index)
                } label: {
                    Image(systemName: "photo.fill")
                        .font(.system(size: fontSize * 0.85))
                        .foregroundColor(card.accentColor.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pasted image \(index + 1). Click to remove.")
            }

            TextField("", text: $userInput)
                .textFieldStyle(.plain)
                .font(.custom("PressStart2P", size: fontSize))
                .foregroundColor(textColor)
                .focused($isInputFocused)
                .onSubmit { submitAnswer(userInput) }
                .accessibilityLabel("Type your answer")
                .accessibilityHint("Press Return to submit. Paste an image with Cmd+V.")

            Button(action: { submitAnswer(userInput) }) {
                Text("OK")
                    .font(.custom("PressStart2P", size: fontSize * 0.75))
                    .foregroundColor(
                        userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && pastedImages.isEmpty
                            ? textColor.opacity(0.25)
                            : card.accentColor
                    )
            }
            .buttonStyle(.plain)
            .disabled(
                userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && pastedImages.isEmpty
            )
            .accessibilityLabel("Submit answer")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(borderColor.opacity(0.6), lineWidth: 1)
        )
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isInputFocused = true
            }
            pasteMonitor.install { [self] data in
                pastedImages.append(data)
            }
        }
        .onDisappear {
            pasteMonitor.uninstall()
        }
    }

    private var proposedAnswerButtons: some View {
        VStack(spacing: 10) {
            ForEach(Array(proposedAnswers.enumerated()), id: \.offset) { _, answer in
                AnswerButton(
                    text: answer,
                    fontSize: fontSize,
                    textColor: textColor,
                    borderColor: borderColor,
                    accentColor: card.accentColor
                ) {
                    submitAnswer(answer)
                }
            }
        }
    }

    private func submitAnswer(_ answer: String) {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pastedImages.isEmpty else { return }
        let images = pastedImages
        pastedImages = []
        viewModel.submitChatAnswer(trimmed, images: images)
    }

    // MARK: Animation sequence

    private func runSequence() async {
        // Set initial width to match notch at current scale
        cardWidth = settings.notchVisualWidth / scale

        if let img = card.image {
            pixelFrames = sharedPixelFactors.map { factor in
                factor >= 1.0 ? img : downsampleImage(img, factor: factor)
            }
        }

        // 1) Wait for the narrow drop to fully settle
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        // 2) Expand sideways
        withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
            cardWidth = OverlayMetrics.expandedWidth
        }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        // — pause before content appears —
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }

        // 3) Image reveal — box grows vertically to fit
        if !pixelFrames.isEmpty {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showImage = true
            }
            let stepCount = pixelFrames.count
            for i in 0..<stepCount {
                guard !Task.isCancelled else { return }
                pixelFrameIndex = i
                withAnimation(.linear(duration: 0.07)) {
                    imageOpacity = Double(i + 1) / Double(stepCount)
                }
                try? await Task.sleep(for: .milliseconds(85))
            }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            // Switch to animated image view if this is a GIF/WebP
            revealComplete = true
        } else if card.imageURL != nil {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                showImage = true
            }
            withAnimation(.easeIn(duration: 0.4)) {
                imageOpacity = 1
            }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
        }

        // 4) Typewriter — box grows down as text wraps
        let allChars = Array(cardFullText(name: card.name, message: card.message))
        for i in 0..<allChars.count {
            guard !Task.isCancelled else { return }
            visibleChars = i + 1
            try? await Task.sleep(for: .milliseconds(Int(settings.textSpeed)))
        }

        // 5) Show input
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) {
            showInput = true
        }
    }
}

// MARK: - Answer Button

private struct AnswerButton: View {
    let text: String
    let fontSize: CGFloat
    let textColor: Color
    let borderColor: Color
    let accentColor: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.custom("PressStart2P", size: fontSize))
                .foregroundColor(isHovered ? accentColor : textColor.opacity(0.88))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isHovered ? accentColor.opacity(0.08) : Color.white.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(
                            isHovered ? accentColor.opacity(0.7) : borderColor.opacity(0.5),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(text)
        .accessibilityHint("Double-tap to select this answer")
    }
}

// MARK: - Compose Notch Card

private struct ComposeNotchCard: View {
    @ObservedObject var settings: OverlaySettings
    let viewModel: NotchOverlayViewModel
    let scale: CGFloat
    var characterName: String = ""

    @State private var userInput: String = ""
    @State private var pastedImages: [Data] = []
    @FocusState private var isInputFocused: Bool
    @State private var pasteMonitor = ImagePasteMonitor()

    private var bgColor: Color { Color(hex: settings.bgColorHex) }
    private var borderColor: Color { Color(hex: settings.borderColorHex) }
    private var textColor: Color { Color(hex: settings.textColorHex) }
    private var accentColor: Color { Color(hex: settings.testNameColorHex) }

    private var fontSize: CGFloat {
        scale < 1.0 ? 12 * 1.5 : 12
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: settings.notchOffset / scale)

            VStack(alignment: .leading, spacing: 10) {
                if !characterName.isEmpty {
                    Text("talking to \(characterName)")
                        .font(.custom("PressStart2P", size: fontSize * 0.6))
                        .foregroundColor(accentColor.opacity(0.4))
                        .accessibilityLabel("Talking to \(characterName)")
                }

                HStack(spacing: 10) {
                    Text(">")
                        .font(.custom("PressStart2P", size: fontSize))
                        .foregroundColor(accentColor.opacity(0.6))
                        .accessibilityHidden(true)

                    // Pasted image icons (tap to remove)
                    ForEach(Array(pastedImages.enumerated()), id: \.offset) { index, _ in
                        Button {
                            pastedImages.remove(at: index)
                        } label: {
                            Image(systemName: "photo.fill")
                                .font(.system(size: fontSize * 0.85))
                                .foregroundColor(accentColor.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pasted image \(index + 1). Click to remove.")
                    }

                    TextField("", text: $userInput)
                        .textFieldStyle(.plain)
                        .font(.custom("PressStart2P", size: fontSize))
                        .foregroundColor(textColor)
                        .focused($isInputFocused)
                        .onSubmit { submit() }
                        .accessibilityLabel("Compose message")
                        .accessibilityHint(
                            characterName.isEmpty
                                ? "Press Return to send. Paste an image with Cmd+V."
                                : "Message \(characterName). Press Return to send. Paste images with Cmd+V."
                        )

                    Button(action: { submit() }) {
                        Text("OK")
                            .font(.custom("PressStart2P", size: fontSize * 0.75))
                            .foregroundColor(
                                userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    && pastedImages.isEmpty
                                    ? textColor.opacity(0.25)
                                    : accentColor
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        userInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && pastedImages.isEmpty
                    )
                    .accessibilityLabel("Send message")
                }

                // Minimize triangle — centered, generous hit target
                Button {
                    viewModel.toggleMinimize()
                } label: {
                    Image(systemName: "chevron.compact.up")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(textColor.opacity(0.3))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Minimize")
                .accessibilityHint("Double-tap to hide this card behind the notch")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .padding(.top, 8)
        }
        .background {
            NotchDropdownShape(cornerRadius: settings.cornerRadius)
                .fill(bgColor)
        }
        .clipShape(NotchDropdownShape(cornerRadius: settings.cornerRadius))
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isInputFocused = true
            }
            pasteMonitor.install { [self] data in
                pastedImages.append(data)
            }
        }
        .onDisappear {
            pasteMonitor.uninstall()
        }
    }

    private func submit() {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !pastedImages.isEmpty else { return }
        let images = pastedImages
        pastedImages = []
        viewModel.submitCompose(trimmed, images: images)
    }
}

// MARK: - Minimized Notch Strip

/// A tiny strip that shows below the notch when the interaction is minimized.
/// Contains a down-chevron triangle to expand back.
private struct MinimizedNotchStrip: View {
    let viewModel: NotchOverlayViewModel
    @ObservedObject var settings: OverlaySettings
    let scale: CGFloat

    private var bgColor: Color { Color(hex: settings.bgColorHex) }
    private var textColor: Color { Color(hex: settings.textColorHex) }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: settings.notchOffset / scale)

            Button {
                viewModel.toggleMinimize()
            } label: {
                Image(systemName: "chevron.compact.down")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(textColor.opacity(0.4))
                    .frame(width: 80, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Expand")
            .accessibilityHint("Double-tap to show the hidden card")
            .padding(.bottom, 12)
        }
        .frame(width: max(settings.notchVisualWidth, 120) / scale)
        .background {
            NotchDropdownShape(cornerRadius: settings.cornerRadius)
                .fill(bgColor)
        }
        .clipShape(NotchDropdownShape(cornerRadius: settings.cornerRadius))
        .compositingGroup()
        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
        .scaleEffect(scale, anchor: .top)
        .frame(width: settings.notchVisualWidth)
    }
}

// MARK: - Placeholder Art

private struct PlaceholderArt: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.6)
            Image(systemName: "photo")
                .font(.system(size: 32, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.25))
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(
            viewModel: {
                let vm = NotchOverlayViewModel()
                vm.apply(
                    OverlayAPIRequest(
                        title: nil,
                        name: "Aki",
                        nameColor: "#7FD6FF",
                        message: "Hi victor!\nHow are you?",
                        imageURL: nil,
                        imageBase64: nil,
                        accentHex: "#7FD6FF",
                        expanded: true
                    ),
                    appearanceDuration: 12
                )
                return vm
            }(),
            settings: OverlaySettings()
        )
        .frame(width: 700, height: 600)
        .background(Color.gray.opacity(0.15))
    }
}
