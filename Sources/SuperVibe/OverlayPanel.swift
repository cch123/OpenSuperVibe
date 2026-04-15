import Cocoa
import SwiftUI

// MARK: - Neon Colors

private let neonCyan    = Color(red: 0, green: 0.94, blue: 1)
private let neonMagenta = Color(red: 1, green: 0, blue: 0.9)
private let neonPurple  = Color(red: 0.48, green: 0.18, blue: 1)
private let neonGreen   = Color(red: 0, green: 1, blue: 0.53)
private let bgDark      = Color(red: 0.04, green: 0.04, blue: 0.08)

// MARK: - Panel

final class OverlayPanel: NSPanel {
    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    func positionCenter() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        // Panel covers a big region, always centered; SwiftUI content centers itself inside
        let w: CGFloat = 700
        let h: CGFloat = 520
        let x = area.midX - w / 2
        let y = area.midY - h / 2
        setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}

// MARK: - ViewModel

final class OverlayViewModel: ObservableObject {
    @Published var stage: SessionStage = .idle
    @Published var asrText = ""
    @Published var gptText = ""
    @Published var isTranslation = false
    @Published var isPolish = false

    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    /// Raw target level set by audio callback (~44 Hz). Not @Published —
    /// the TimelineView in RecordingHUD drives rendering, so we don't need
    /// a separate Timer or Published property to trigger SwiftUI updates.
    private(set) var targetLevel: CGFloat = 0

    /// Smoothed level, updated each TimelineView frame (30 FPS).
    /// Not @Published — read directly by the TimelineView content closure.
    private(set) var smoothedLevel: CGFloat = 0

    func pushLevel(_ level: Float) {
        targetLevel = CGFloat(level)
    }

    /// Called once per TimelineView frame to advance the smoothing filter.
    func updateSmoothing() {
        if targetLevel > smoothedLevel {
            smoothedLevel += (targetLevel - smoothedLevel) * 0.40
        } else {
            smoothedLevel += (targetLevel - smoothedLevel) * 0.15
        }
    }

    func resetLevels() {
        smoothedLevel = 0
        targetLevel = 0
    }
}

// MARK: - Root

struct OverlayRootView: View {
    @ObservedObject var vm: OverlayViewModel

    /// Only changes when the visual layout actually switches (recording ↔ text ↔ error).
    /// Recognizing/translating/done all share the same text card, so no animation between them.
    private var visualPhase: Int {
        switch vm.stage {
        case .recording: return 0
        case .recognizing, .translating, .done: return 1
        case .error: return 2
        default: return -1
        }
    }

    var body: some View {
        Group {
            switch vm.stage {
            case .recording:
                RecordingHUD(
                    vm: vm,
                    accent: vm.isTranslation ? neonMagenta : neonCyan,
                    onCancel: vm.onCancel,
                    onConfirm: vm.onConfirm
                )
            case .recognizing, .translating, .done:
                if vm.isTranslation || vm.isPolish {
                    CyberTranslatingCard(
                        asrText: vm.asrText,
                        gptText: vm.gptText,
                        isTranscribing: vm.stage == .recognizing,
                        isDone: vm.stage == .done,
                        isPolish: vm.isPolish
                    )
                } else {
                    CyberTextCard(accent: neonCyan, label: vm.stage == .done ? "TRANSCRIBED" : "TRANSCRIBING", text: vm.asrText)
                }
            case .error:
                CyberInfoCard(label: "ERROR", accent: Color(red: 1, green: 0.2, blue: 0.2))
            default:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: visualPhase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Cyber Card Chrome

struct CyberCard<Content: View>: View {
    var accent: Color = neonCyan
    @ViewBuilder let content: Content
    @State private var borderPhase: CGFloat = 0

    var body: some View {
        content
            .padding(24)
            .frame(maxWidth: 560)
            .background {
                ZStack {
                    // Deep dark bg
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(bgDark)

                    // Subtle grid / scan lines
                    ScanLines()
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                    // Animated neon border
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            AngularGradient(
                                colors: [accent, accent.opacity(0.1), neonPurple.opacity(0.4), accent],
                                center: .center,
                                angle: .degrees(borderPhase)
                            ),
                            lineWidth: 1.5
                        )


                }
                .shadow(color: accent.opacity(0.3), radius: 20, y: 0)
            }
            .onAppear {
                withAnimation(.linear(duration: 4).repeatForever(autoreverses: false)) {
                    borderPhase = 360
                }
            }
    }
}

struct ScanLines: View {
    var body: some View {
        Canvas { ctx, size in
            for y in stride(from: 0, to: size.height, by: 3) {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                ctx.fill(Path(rect), with: .color(.white.opacity(0.015)))
            }
        }
    }
}

// MARK: - 1. Recording HUD

struct RecordingHUD: View {
    let vm: OverlayViewModel
    var accent: Color = neonCyan
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private let count = 12
    /// Bell-curve weights: center high, sides low
    private let weights: [CGFloat] = {
        (0..<12).map { i in
            let x = (CGFloat(i) - 5.5) / 3.0
            return 0.35 + 0.65 * exp(-x * x)
        }
    }()
    private let barWidth: CGFloat = 5
    private let barSpacing: CGFloat = 3.5
    private let minH: CGFloat = 4
    private let maxH: CGFloat = 46

    var body: some View {
        HStack(spacing: 18) {
            // Cancel
            Button(action: { onCancel?() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.6))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(accent.opacity(0.08)))
                    .overlay(Circle().stroke(accent.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)

            // 5-bar waveform — 30 FPS is plenty for smooth animation
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let _ = vm.updateSmoothing()
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(0..<count, id: \.self) { i in
                        let h = barH(i, t)
                        RoundedRectangle(cornerRadius: barWidth / 2)
                            .fill(accent)
                            .shadow(color: accent.opacity(0.5), radius: 3)
                            .frame(width: barWidth, height: h)
                    }
                }
                .frame(height: 50)
            }

            // Confirm
            Button(action: { onConfirm?() }) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(neonGreen)
                    .shadow(color: neonGreen.opacity(0.5), radius: 3)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(neonGreen.opacity(0.1)))
                    .overlay(Circle().stroke(neonGreen.opacity(0.25), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(bgDark)
                ScanLines().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(accent.opacity(0.3), lineWidth: 1)
                // (corner brackets removed)
            }
            .shadow(color: accent.opacity(0.15), radius: 16)
        }
    }

    private func barH(_ i: Int, _ t: Double) -> CGFloat {
        let w = weights[i]
        let fi = Double(i)
        // Multi-frequency jitter for lively movement
        let j1 = sin(t * 13.0 + fi * 2.7) * 0.22
        let j2 = sin(t * 7.3 + fi * 4.1) * 0.15
        let jitter = 1.0 + j1 + j2
        // Ensure at least ~20% amplitude even at low audio levels
        let boosted = max(vm.smoothedLevel, 0.2)
        let h = minH + boosted * w * CGFloat(jitter) * (maxH - minH)
        return max(minH, h)
    }
}

// MARK: - 2. Text Card

struct CyberTextCard: View {
    let accent: Color
    let label: String
    let text: String
    @State private var dotPhase = 0
    @State private var timer: Timer?

    /// Show only the tail when text is very long so the card stays compact.
    private var tailText: String {
        if text.count <= 400 { return text }
        return "…" + text.suffix(400)
    }

    private var isDone: Bool { label == "TRANSCRIBED" }

    var body: some View {
        CyberCard(accent: accent) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    SpinArc(color: accent)
                        .frame(width: 14, height: 14)
                        .opacity(isDone ? 0 : 1)

                    Text(label)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(accent)
                        .shadow(color: accent.opacity(0.6), radius: 3)

                    HStack(spacing: 3) {
                        ForEach(0..<3, id: \.self) { i in
                            Circle()
                                .fill(accent.opacity(i < dotPhase ? 0.9 : 0.15))
                                .frame(width: 4, height: 4)
                                .shadow(color: accent.opacity(i < dotPhase ? 0.5 : 0), radius: 2)
                                .animation(.easeInOut(duration: 0.15), value: dotPhase)
                        }
                    }
                    .opacity(isDone ? 0 : 1)
                }
                .frame(maxWidth: .infinity)

                if text.isEmpty {
                    CyberShimmer(color: accent)
                } else {
                    Text(tailText)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: accent.opacity(0.15), radius: 2)
                        .lineSpacing(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .onAppear { startDots() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func startDots() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            DispatchQueue.main.async { dotPhase = (dotPhase + 1) % 4 }
        }
    }
}

struct SpinArc: View {
    let color: Color
    @State private var rot: Double = 0
    var body: some View {
        Circle()
            .trim(from: 0, to: 0.25)
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .shadow(color: color, radius: 3)
            .rotationEffect(.degrees(rot))
            .onAppear {
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) {
                    rot = 360
                }
            }
    }
}

struct CyberShimmer: View {
    let color: Color
    @State private var phase: CGFloat = -0.5

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(0.05))
            .frame(height: 14)
            .frame(maxWidth: 200)
            .overlay(
                GeometryReader { geo in
                    Capsule()
                        .fill(color.opacity(0.2))
                        .frame(width: geo.size.width * 0.3)
                        .blur(radius: 6)
                        .offset(x: phase * geo.size.width)
                }
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    phase = 1.5
                }
            }
    }
}

// MARK: - Translating Card (ASR + GPT)

struct CyberTranslatingCard: View {
    let asrText: String
    let gptText: String
    var isTranscribing: Bool = false
    var isDone: Bool = false
    var isPolish: Bool = false
    @State private var dotPhase = 0
    @State private var timer: Timer?

    private var secondaryAccent: Color { isPolish ? neonCyan : neonMagenta }
    private var secondaryLabelDone: String { isPolish ? "POLISHED" : "TRANSLATED" }
    private var secondaryLabelActive: String { isPolish ? "POLISHING" : "TRANSLATION" }

    private var tailASR: String {
        if asrText.count <= 200 { return asrText }
        return "…" + asrText.suffix(200)
    }
    private var tailGPT: String {
        if gptText.count <= 400 { return gptText }
        return "…" + gptText.suffix(400)
    }

    private var showSpinner: Bool { !isTranscribing && !isDone }

    var body: some View {
        CyberCard(accent: isPolish ? neonCyan : neonMagenta) {
            VStack(alignment: .leading, spacing: 14) {
                // ASR original text
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        SpinArc(color: neonCyan)
                            .frame(width: 14, height: 14)
                            .opacity(isTranscribing ? 1 : 0)
                        Text(isTranscribing ? "TRANSCRIBING" : "TRANSCRIBED")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(neonCyan.opacity(isTranscribing ? 1 : 0.7))
                            .shadow(color: neonCyan.opacity(isTranscribing ? 0.6 : 0), radius: 3)
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(neonCyan.opacity(i < dotPhase ? 0.9 : 0.15))
                                    .frame(width: 4, height: 4)
                                    .animation(.easeInOut(duration: 0.15), value: dotPhase)
                            }
                        }
                        .opacity(isTranscribing ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)

                    if asrText.isEmpty {
                        CyberShimmer(color: neonCyan)
                    } else {
                        Text(tailASR)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white.opacity(isTranscribing ? 0.9 : 0.5))
                            .lineSpacing(3)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                // Divider
                Rectangle()
                    .fill(secondaryAccent.opacity(0.2))
                    .frame(height: 1)

                // Translation / Polish
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        SpinArc(color: secondaryAccent)
                            .frame(width: 14, height: 14)
                            .opacity(showSpinner ? 1 : 0)
                        Text(isDone ? secondaryLabelDone : secondaryLabelActive)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(secondaryAccent.opacity(isTranscribing ? 0.3 : 1))
                            .shadow(color: secondaryAccent.opacity(isTranscribing ? 0 : 0.6), radius: 3)
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { i in
                                Circle()
                                    .fill(secondaryAccent.opacity(i < dotPhase ? 0.9 : 0.15))
                                    .frame(width: 4, height: 4)
                                    .shadow(color: secondaryAccent.opacity(i < dotPhase ? 0.5 : 0), radius: 2)
                                    .animation(.easeInOut(duration: 0.15), value: dotPhase)
                            }
                        }
                        .opacity(showSpinner ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)

                    if gptText.isEmpty {
                        Text(isTranscribing ? "Waiting for transcription..." : "")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.2))
                            .frame(height: 14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay {
                                if !isTranscribing { CyberShimmer(color: secondaryAccent) }
                            }
                    } else {
                        Text(tailGPT)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: secondaryAccent.opacity(0.15), radius: 2)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .onAppear { startDots() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func startDots() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
            DispatchQueue.main.async { dotPhase = (dotPhase + 1) % 4 }
        }
    }
}

// MARK: - 3. Done

struct CyberDoneCard: View {
    let text: String
    @State private var scale: CGFloat = 0.3
    @State private var glow = false

    var body: some View {
        CyberCard(accent: neonGreen) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(neonGreen)
                    .shadow(color: neonGreen.opacity(glow ? 0.8 : 0.3), radius: glow ? 8 : 3)
                    .scaleEffect(scale)

                Text(text.isEmpty ? "DONE" : text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { scale = 1.0 }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { glow = true }
        }
    }
}

// MARK: - 4. Info

struct CyberInfoCard: View {
    let label: String
    let accent: Color

    var body: some View {
        CyberCard(accent: accent) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(accent)
                    .shadow(color: accent, radius: 4)
                Text(label)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(accent)
            }
            .frame(maxWidth: .infinity)
        }
    }
}
