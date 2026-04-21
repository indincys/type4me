import SwiftUI

/// Cached font for text measurement (module-level to avoid generic-type static restriction).
private let floatingBarFont = NSFont.systemFont(ofSize: 14, weight: .medium)
private let floatingBarRecordingBaseWidth: CGFloat = 154

// MARK: - FloatingBarState Protocol

@MainActor
protocol FloatingBarState: AnyObject, Observable {
    var barPhase: FloatingBarPhase { get }
    var segments: [TranscriptionSegment] { get }
    var audioLevel: AudioLevelMeter { get }
    var currentMode: ProcessingMode { get }
    var feedbackMessage: String { get }
    var processingFinishTime: Date? { get }
    var transcriptionText: String { get }
    var recordingStartDate: Date? { get }
    /// True when recording without SenseVoice streaming (Qwen3-only).
    var isQwen3OnlyMode: Bool { get }
    var effectiveProcessingLabel: String { get }
}

/// Liquid Glass floating transcription bar with smooth morphing between states.
///
/// Design: single glass capsule that animates width + content transitions.
/// - Recording: audio-reactive glass control + live transcript
/// - Processing: glass progress field + processing label
/// - Done: completed progress field + centered feedback
struct FloatingBarView<S: FloatingBarState>: View {

    let state: S

    @State private var breathe = false
    @State private var doneGlow = true
    /// High-water mark: only grows during recording, never shrinks (prevents ASR correction jitter)
    @State private var recordingPeakWidth: CGFloat = floatingBarRecordingBaseWidth
    @State private var processingStartDate: Date?
    @State private var doneStartDate: Date?
    @State private var isHovered = false
    @AppStorage("tf_hoverTranscriptPreview") private var hoverTranscriptPreview = true
    @AppStorage("tf_visualStyle") private var visualStyle = "timeline"

    // MARK: - Transcript Popup

    private var showTranscriptPopup: Bool {
        guard hoverTranscriptPreview, isHovered, state.barPhase == .recording, !state.segments.isEmpty else { return false }
        let textWidth = measureText(state.transcriptionText)
        return textWidth + 96 > TF.barWidth
    }

    private var effectsEnabled: Bool {
        visualStyle != "off"
    }

    private var capsuleWidth: CGFloat {
        switch state.barPhase {
        case .preparing:
            return effectsEnabled ? TF.barHeight : floatingBarRecordingBaseWidth
        case .recording:
            if state.segments.isEmpty {
                return floatingBarRecordingBaseWidth
            }
            return recordingPeakWidth
        case .processing:
            return measureText(state.effectiveProcessingLabel) + 66.0
        case .done:
            return feedbackWidth(for: state.feedbackMessage)
        case .error:
            return feedbackWidth(for: state.feedbackMessage)
        case .hidden:
            return TF.barHeight
        }
    }

    var body: some View {
        floatingStack
            .background {
                FloatingBarHoverTracker { hovered in
                    withAnimation(TF.springSnappy) {
                        isHovered = hovered
                    }
                }
            }
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .animation(TF.springSnappy, value: state.barPhase != .hidden)
            .animation(TF.springSnappy, value: showTranscriptPopup)
            .onChange(of: state.barPhase) { _, newPhase in
                handlePhaseChange(newPhase)
            }
            .onChange(of: state.segments) { _, newSegments in
                guard state.barPhase == .recording else { return }
                let text = newSegments.map(\.text).joined()
                let textWidth = measureText(text)
                let needed = min(TF.barWidth, max(floatingBarRecordingBaseWidth, textWidth + 96.0))
                if needed > recordingPeakWidth {
                    // Growing: fixed velocity 250pt/s
                    let distance = needed - recordingPeakWidth
                    let duration = max(0.12, Double(distance / 250.0))
                    withAnimation(.linear(duration: duration)) {
                        recordingPeakWidth = needed
                    }
                } else if recordingPeakWidth - needed > 30 {
                    // Large correction (hotword etc.): allow shrink
                    withAnimation(.easeInOut(duration: 0.2)) {
                        recordingPeakWidth = needed
                    }
                }
            }
    }

    @ViewBuilder
    private var floatingStack: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: TF.transcriptPopupGap) {
                stackContent
            }
        } else {
            stackContent
        }
    }

    private var stackContent: some View {
        VStack(spacing: TF.transcriptPopupGap) {
            if showTranscriptPopup {
                transcriptPopup
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95, anchor: .bottom).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if state.barPhase != .hidden {
                capsuleBar
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.92).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
    }

    // MARK: - Capsule Container

    private var capsuleBar: some View {
        ZStack {
            capsuleBackground

            barContent
                .animation(TF.springSnappy, value: state.barPhase)
        }
        .frame(width: capsuleWidth, height: TF.barHeight)
        .clipShape(Capsule())
        .floatingGlass(tint: glassTint, in: Capsule())
        .overlay { capsuleBorder }
        .shadow(color: shadowColor, radius: shadowRadius, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 0)
        .animation(TF.springSnappy, value: state.barPhase)
    }

    // MARK: - Content by Phase

    @ViewBuilder
    private var barContent: some View {
        switch state.barPhase {
        case .preparing:
            preparingContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.92).combined(with: .opacity),
                    removal: .opacity
                ))
        case .recording:
            recordingContent
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity)
                ))
        case .processing:
            processingContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .scale(scale: 0.9).combined(with: .opacity)
                ))
        case .done:
            doneContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .opacity
                ))
        case .error:
            errorContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                    removal: .opacity
                ))
        case .hidden:
            EmptyView()
        }
    }

    private var preparingContent: some View {
        HStack(spacing: 0) {
            if effectsEnabled {
                PreparingDot()
            } else {
                StaticRecordingIndicator()
                Text(L("准备中", "Preparing"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, effectsEnabled ? 0 : 12)
        .padding(.trailing, effectsEnabled ? 0 : 16)
        .frame(maxWidth: .infinity)
    }

    private var recordingContent: some View {
        HStack(spacing: 10) {
            // Module 1: fixed leading indicator keeps transcript text stable.
            if effectsEnabled {
                LiquidRecordingIndicator(meter: state.audioLevel)
            } else {
                StaticRecordingIndicator()
            }

            // Module 2: text container (fills remaining space, grows with frame)
            // Uses overlay so text sizing never affects HStack layout
            if state.segments.isEmpty {
                Text(L("聆听中", "Listening"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            } else if !state.segments.isEmpty {
                Color.clear
                    .overlay(alignment: .trailing) {
                        Text(state.transcriptionText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .mask {
                        if recordingPeakWidth >= TF.barWidth {
                            HStack(spacing: 0) {
                                LinearGradient(
                                    colors: [.clear, .white],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 12)
                                Rectangle()
                            }
                        } else {
                            Rectangle()
                        }
                    }
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
    }

    private var processingContent: some View {
        ZStack {
            Text(state.effectiveProcessingLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    private var doneContent: some View {
        ZStack {
            Text(state.feedbackMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
    }

    private var errorContent: some View {
        HStack(spacing: 10) {
            ErrorDot()

            Text(state.feedbackMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
    }

    // MARK: - Background & Border

    private var capsuleBackground: some View {
        ZStack {
            Capsule()
                .fill(
                    LinearGradient(
                        colors: glassOverlayColors,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if state.barPhase == .recording && effectsEnabled {
                AudioRipple(meter: state.audioLevel)
                    .transition(.opacity)
            }

            if effectsEnabled && (state.barPhase == .processing || state.barPhase == .done) {
                ProcessingProgress(
                    finishTime: state.processingFinishTime,
                    processingStartDate: processingStartDate,
                    doneStartDate: doneStartDate
                )
                .transition(.opacity)
            }

            if state.barPhase == .error {
                LinearGradient(
                    colors: [TF.settingsAccentRed.opacity(0.16), .clear],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.45, y: 0.5)
                )
                .transition(.opacity)
            }
        }
    }

    private var capsuleBorder: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(borderColor.opacity),
                        phaseAccent.opacity(borderColor.accentOpacity),
                        Color.white.opacity(effectsEnabled ? 0.06 : 0.12),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private var glassTint: Color? {
        switch state.barPhase {
        case .recording:
            effectsEnabled ? TF.recording.opacity(0.08) : nil
        case .processing:
            effectsEnabled ? Color.blue.opacity(0.06) : nil
        case .done:
            effectsEnabled ? TF.success.opacity(0.08) : nil
        case .error:
            TF.settingsAccentRed.opacity(0.10)
        default:
            nil
        }
    }

    private var phaseAccent: Color {
        if !effectsEnabled && state.barPhase != .error {
            return Color.white
        }
        return switch state.barPhase {
        case .recording:
            TF.recording
        case .processing:
            Color(red: 0.32, green: 0.54, blue: 0.95)
        case .done:
            TF.success
        case .error:
            TF.settingsAccentRed
        default:
            Color.white
        }
    }

    private var glassOverlayColors: [Color] {
        if !effectsEnabled && state.barPhase != .error {
            return [
                Color.white.opacity(0.10),
                Color.white.opacity(0.025),
                Color.white.opacity(0.015),
            ]
        }
        return [
            Color.white.opacity(0.14),
            phaseAccent.opacity(0.08),
            Color.white.opacity(0.025),
        ]
    }

    private var shadowColor: Color {
        if !effectsEnabled && state.barPhase != .error {
            return Color.black.opacity(0.14)
        }
        return switch state.barPhase {
        case .recording:
            TF.recording.opacity(0.18)
        case .processing:
            Color.blue.opacity(0.14)
        case .done:
            TF.success.opacity(0.16)
        case .error:
            TF.settingsAccentRed.opacity(0.16)
        default:
            Color.black.opacity(0.14)
        }
    }

    private var shadowRadius: CGFloat {
        if !effectsEnabled && state.barPhase != .error {
            return 14
        }
        return state.barPhase == .recording && breathe ? 18 : 12
    }

    private var borderColor: (opacity: Double, accentOpacity: Double) {
        switch state.barPhase {
        case .preparing:
            effectsEnabled ? (0.28, 0.08) : (0.32, 0.00)
        case .recording:
            effectsEnabled ? (breathe ? 0.42 : 0.24, 0.26) : (0.32, 0.00)
        case .processing:
            effectsEnabled ? (0.32, 0.20) : (0.32, 0.00)
        case .done:
            effectsEnabled ? (doneGlow ? 0.42 : 0.24, doneGlow ? 0.30 : 0.14) : (0.32, 0.00)
        case .error:
            (0.34, 0.30)
        case .hidden:
            (0, 0)
        }
    }

    // MARK: - Phase Transitions

    private func handlePhaseChange(_ phase: FloatingBarPhase) {
        switch phase {
        case .preparing:
            recordingPeakWidth = floatingBarRecordingBaseWidth
            processingStartDate = nil
            doneStartDate = nil
            breathe = false
            if effectsEnabled {
                withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
        case .recording:
            recordingPeakWidth = floatingBarRecordingBaseWidth
            breathe = false
            if effectsEnabled {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
        case .processing:
            processingStartDate = Date()
            doneStartDate = nil
            breathe = false
        case .done:
            doneStartDate = Date()
            breathe = false
            doneGlow = true
            if effectsEnabled {
                withAnimation(.easeOut(duration: 1.0)) { doneGlow = false }
            }
        case .error:
            breathe = false
            doneGlow = false
        default:
            breathe = false
        }
    }

    private func feedbackWidth(for message: String) -> CGFloat {
        measureText(message) + 66.0
    }

    /// Measure actual rendered width using the same font as the floating bar text.
    private func measureText(_ string: String) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: floatingBarFont]).width)
    }

    // MARK: - Transcript Popup View

    private var transcriptPopup: some View {
        Text(state.transcriptionText)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .frame(width: TF.barWidth)
            .clipShape(RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous))
            .floatingGlass(
                tint: Color.white.opacity(0.04),
                in: RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.16), radius: 12, y: -2)
    }
}

// MARK: - Recording Dot

struct PreparingDot: View {

    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(TF.recording.opacity(0.16), lineWidth: 1.6)
                .frame(width: 14, height: 14)

            Circle()
                .trim(from: 0.16, to: 0.76)
                .stroke(
                    TF.recording,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: 24, height: 24)
        .onAppear {
            rotation = 0
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Recording Dot

/// Audio-reactive red dot with dual concentric pulse rings.
struct RecordingDot: View {

    let meter: AudioLevelMeter

    @State private var outerPulse = false
    @State private var innerPulse = false

    var body: some View {
        TimelineView(.animation) { _ in
            let level = CGFloat(max(0.05, min(1.0, meter.current)))
            let levelSize: CGFloat = 10 + level * 12

            ZStack {
                // Outer slow pulse ring
                Circle()
                    .fill(TF.recording.opacity(outerPulse ? 0.0 : 0.25))
                    .frame(width: outerPulse ? 24 : 10, height: outerPulse ? 24 : 10)

                // Audio-reactive ring (smooth following)
                Circle()
                    .fill(TF.recording.opacity(0.18))
                    .frame(width: levelSize, height: levelSize)

                // Inner faster pulse ring (offset phase)
                Circle()
                    .stroke(TF.recording.opacity(innerPulse ? 0.2 : 0.0), lineWidth: 1)
                    .frame(width: innerPulse ? 18 : 12, height: innerPulse ? 18 : 12)

                // Core dot
                Circle()
                    .fill(TF.recording)
                    .frame(width: 10, height: 10)
                    .shadow(color: TF.recording.opacity(0.4), radius: 3)
            }
        }
        .frame(width: 24, height: 24)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                outerPulse = true
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(0.15)) {
                innerPulse = true
            }
        }
    }
}

// MARK: - Liquid Recording Indicator

/// Compact glass control that combines a live mic dot with a small waveform.
struct LiquidRecordingIndicator: View {

    let meter: AudioLevelMeter

    var body: some View {
        HStack(spacing: 6) {
            RecordingDot(meter: meter)
                .frame(width: 20, height: 20)

            LiquidMeterBars(meter: meter)
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 8)
        .frame(width: 62, height: 34)
        .clipShape(Capsule())
        .floatingGlass(tint: TF.recording.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
        }
    }
}

struct LiquidMeterBars: View {

    let meter: AudioLevelMeter
    private let phases: [Double] = [0, 0.65, 1.35]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let level = CGFloat(max(0.08, min(1.0, meter.current)))

            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    let wave = CGFloat(sin(time * 5.2 + phases[index] * .pi) * 0.5 + 0.5)
                    let height = 6 + wave * 12 * level
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.primary.opacity(0.45 + wave * 0.35))
                        .frame(width: 3.5, height: height)
                }
            }
        }
    }
}

struct StaticRecordingIndicator: View {

    var body: some View {
        ZStack {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
        }
        .frame(width: 34, height: 34)
        .clipShape(Circle())
        .floatingGlass(tint: nil, in: Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        }
    }
}

// MARK: - Processing Orb

/// Purple/blue gradient sphere with rotation + breathing glow.
struct ProcessingOrb: View {

    @State private var rotation: Double = 0
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [
                        Color(red: 0.40, green: 0.30, blue: 0.90),
                        Color(red: 0.30, green: 0.55, blue: 1.00),
                        Color(red: 0.40, green: 0.30, blue: 0.90),
                    ],
                    center: .center,
                    startAngle: .degrees(rotation),
                    endAngle: .degrees(rotation + 360)
                )
            )
            .frame(width: 22, height: 22)
            .scaleEffect(breathe ? 1.08 : 0.95)
            .shadow(
                color: Color(red: 0.35, green: 0.35, blue: 0.90).opacity(breathe ? 0.6 : 0.3),
                radius: breathe ? 10 : 5
            )
            .onAppear {
                withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}

struct ErrorDot: View {

    var body: some View {
        ZStack {
            Circle()
                .fill(TF.settingsAccentRed.opacity(0.18))
                .frame(width: 16, height: 16)

            Text("!")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TF.settingsAccentRed)
                .offset(y: -0.5)
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Recording Timer

/// Shows elapsed time since recording started, updates every second.
struct RecordingTimer: View {

    let startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = startDate.map { timeline.date.timeIntervalSince($0) } ?? 0
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            Text(String(format: "%02d:%02d", minutes, seconds))
        }
    }
}

// MARK: - Processing Progress

/// Particle progress bar with two-phase fill:
/// - Fast phase: 0% → 70% in 1.5s (ease-out)
/// - Slow cruise: 70% → 95% asymptotically (never stalls, always creeping)
/// When processingFinishTime is set, sprints toward 100% in 0.3s.
/// When doneStartDate is set, fills remaining gap to 100% in 0.15s.
/// All timing comes from parent — no @State, so view recreation is harmless.
struct ProcessingProgress: View {

    let finishTime: Date?
    var processingStartDate: Date?
    var doneStartDate: Date?

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let startRef = processingStartDate?.timeIntervalSinceReferenceDate ?? time
                let elapsed = time - startRef

                var progress: CGFloat
                let cruiseProgress: CGFloat
                if elapsed <= 1.5 {
                    // Fast phase: ease-out to 70%
                    let t = min(1.0, CGFloat(elapsed / 1.5))
                    cruiseProgress = t * 0.7 * (2.0 - t)
                } else {
                    // Slow cruise: 70% → 95%, exponential approach (τ=6s)
                    let slowT = 1.0 - exp(-(elapsed - 1.5) / 6.0)
                    cruiseProgress = 0.7 + CGFloat(slowT) * 0.25
                }

                if let finishTime {
                    let finishElapsed = time - finishTime.timeIntervalSinceReferenceDate
                    let sprintT = min(1.0, CGFloat(finishElapsed / 0.3))
                    progress = cruiseProgress + (1.0 - cruiseProgress) * sprintT
                } else {
                    progress = cruiseProgress
                }

                // Done: fill remaining gap to 100% in 0.15s
                if let doneStartDate {
                    let doneElapsed = time - doneStartDate.timeIntervalSinceReferenceDate
                    let doneT = min(1.0, CGFloat(doneElapsed / 0.15))
                    let base = max(progress, 0.7)
                    progress = base + (1.0 - base) * doneT
                }

                // Push soft leading edge past visible boundary when full
                let fillEdge = progress * size.width + (progress >= 0.99 ? 20 : 0)
                let center = size.height / 2

                var col = 0
                var xi: CGFloat = 0
                while xi <= size.width {
                    let nx = xi / size.width

                    // Color: white (left) → blue (right)
                    let t = min(1.0, max(0, nx))
                    let cr = 0.82 - t * 0.42
                    let cg = 0.85 - t * 0.25
                    let coreColor = Color(red: cr, green: cg, blue: 1.0)

                    // Density: filled region is dense, edge has a soft falloff
                    let distToEdge = fillEdge - xi
                    let edgeFade: CGFloat
                    if distToEdge > 20 {
                        edgeFade = 1.0  // fully filled
                    } else if distToEdge > 0 {
                        edgeFade = distToEdge / 20  // soft leading edge
                    } else if distToEdge > -15 {
                        edgeFade = max(0, (distToEdge + 15) / 15) * 0.3  // sparse scatter ahead
                    } else {
                        col += 1; xi += 2; continue
                    }

                    let count = Int(edgeFade * 200)
                    for j in 0..<count {
                        let h1 = hash(col, j)
                        let h2 = hash(col, j &+ 53)
                        let h3 = hash(col, j &+ 137)

                        // Scatter vertically, dense at center
                        let scatter = (h1 - 0.5) * 2
                        let py = center + scatter * abs(scatter) * size.height * 0.48

                        // Fade from center outward
                        let distFromCenter = abs(py - center)
                        let distFade = pow(max(0, 1.0 - distFromCenter / (size.height * 0.48)), 1.3)

                        // Twinkle
                        let freq = 3.0 + Double(h2) * 10.0
                        let twinkle = CGFloat(0.5 + 0.5 * sin(time * freq + Double(h3) * .pi * 2))

                        let op = Double(distFade * twinkle * edgeFade * 0.85)
                        guard op > 0.03 else { continue }

                        let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                        context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(op)))
                    }

                    col += 1
                    xi += 2
                }
            }
        }
        .drawingGroup()
    }

    private func hash(_ a: Int, _ b: Int) -> CGFloat {
        var h = a &* 374761393 &+ b &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return CGFloat(abs(h) % 10000) / 10000.0
    }
}

// MARK: - Audio Ripple

/// Audio visualizer with three selectable styles:
/// - classic: two sine-wave stroke lines
/// - dual: particles clustered around two sine-wave spines
/// - timeline: scrolling level history, right = now
struct AudioRipple: View {

    let meter: AudioLevelMeter
    @AppStorage("tf_visualStyle") private var style = "timeline"
    @State private var smootherSlow = LevelSmoother(timeConstant: 0.8)
    @State private var smootherFast = LevelSmoother(timeConstant: 0)
    @State private var startTime: Double = 0
    @State private var levelTimeline = LevelTimeline()

    var body: some View {
        if style == "off" {
            EmptyView()
        } else {
            TimelineView(.animation) { timeline in
                let time = timeline.date.timeIntervalSinceReferenceDate
                Canvas { context, size in
                    switch style {
                    case "classic": drawClassicWaves(context: &context, size: size, time: time)
                    case "dual": drawDualSpine(context: &context, size: size, time: time)
                    default: drawTimeline(context: &context, size: size, time: time)
                    }
                }
            }
            .drawingGroup()
        }
    }

    // MARK: - Classic Waves (stroke lines only)

    private func drawClassicWaves(context: inout GraphicsContext, size: CGSize, time: Double) {
        let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
        smootherSlow.target = max(0.012, rawLevel)
        let level = smootherSlow.update(time: time)
        let amp = min(1.0, pow(max(0, (level - 0.012) / 0.45), 0.7))
        let center = size.height / 2
        let maxAmp = size.height * (0.15 + amp * 0.35)
        let opacity = 0.4 + Double(amp) * 0.4

        for w in 0..<2 {
            let period: Double = w == 0 ? 130.0 : 90.0
            let speed: Double = w == 0 ? 1.0 : 0.7
            let phase: Double = w == 0 ? 0.0 : 1.3

            var path = Path()
            var first = true
            var xi: CGFloat = 0
            while xi <= size.width {
                let nx = Double(xi / size.width)
                let env = 0.07 + pow(nx, 1.5) * (0.10 + Double(amp))
                let y = center + CGFloat(sin(Double(xi) / period * .pi * 2 + time * speed * .pi + phase) * env) * maxAmp
                if first { path.move(to: CGPoint(x: xi, y: y)); first = false }
                else { path.addLine(to: CGPoint(x: xi, y: y)) }
                xi += 2
            }

            context.stroke(path, with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.82, green: 0.85, blue: 1.0).opacity(opacity * 0.7),
                    Color(red: 0.40, green: 0.60, blue: 1.0).opacity(opacity)
                ]),
                startPoint: CGPoint(x: 0, y: center),
                endPoint: CGPoint(x: size.width, y: center)
            ), lineWidth: 1.5)
        }
    }

    // MARK: - Dual Spine Particles

    private func drawDualSpine(context: inout GraphicsContext, size: CGSize, time: Double) {
        let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
        smootherSlow.target = max(0.012, rawLevel)
        let level = smootherSlow.update(time: time)
        let amp = min(1.0, pow(max(0, (level - 0.012) / 0.45), 0.7))
        let center = size.height / 2
        let maxAmp = size.height * (0.15 + amp * 0.35)
        let levelBright: CGFloat = 0.75 + amp * 0.25
        let bandHalf: CGFloat = size.height * (0.2 + amp * 0.3)

        var xi: CGFloat = 0
        var col = 0
        while xi <= size.width {
            let nx = xi / size.width
            let env = 0.07 + pow(Double(nx), 1.5) * (0.10 + Double(amp))
            let s1y = center + CGFloat(sin(Double(xi) / 130.0 * .pi * 2 + time * .pi) * env) * maxAmp
            let s2y = center + CGFloat(sin(Double(xi) / 90.0 * .pi * 2 + time * 0.7 * .pi) * env) * maxAmp
            let localAmp = (abs(s1y - center) + abs(s2y - center)) / 2
            let localIntensity = min(1.0, localAmp / max(maxAmp * 0.5, 1))
            let posBright: CGFloat = 0.6 + pow(nx, 0.8) * 0.4

            let cr: Double = 0.82 - Double(nx) * 0.42
            let cg: Double = 0.85 - Double(nx) * 0.25
            let coreColor = Color(red: cr, green: cg, blue: 1.0)

            let count = 160 + Int(localIntensity * 120)
            let posScale: CGFloat = 0.4 + pow(nx, 0.8) * 0.6
            let localBand = bandHalf * posScale * (0.5 + amp * 1.0)

            for j in 0..<count {
                let h1 = hash(col, j)
                let h2 = hash(col, j &+ 53)
                let h3 = hash(col, j &+ 137)
                let h5 = hash(col, j &+ 293)

                let spineY = h5 > 0.5 ? s1y : s2y
                let scatter = (h1 - 0.5) * 2
                let py = spineY + scatter * abs(scatter) * localBand

                let distFromSpine = abs(py - spineY)
                let normDist = distFromSpine / max(localBand, 1)
                let distFade: CGFloat = normDist < 0.25 ? 1.0 : max(0, 1.0 - (normDist - 0.25) / 0.75)

                let freq = 3.0 + Double(h2) * 10.0
                let twinkle: CGFloat = 0.45 + 0.55 * CGFloat(sin(time * freq + Double(h3) * .pi * 2))

                let baseOp = posBright * distFade * twinkle * levelBright
                guard baseOp > 0.02 else { continue }

                let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(Double(min(1.0, baseOp)))))
            }

            col += 1
            xi += 2
        }
    }

    // MARK: - Timeline Particles (scrolling history)

    private func drawTimeline(context: inout GraphicsContext, size: CGSize, time: Double) {
        if startTime == 0 { DispatchQueue.main.async { startTime = time } }
        let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
        smootherFast.target = max(0.005, rawLevel)
        let smoothed = smootherFast.update(time: time)
        let levels = levelTimeline.update(time: time, currentLevel: smoothed)

        let center = size.height / 2
        let bufCount = levels.count
        let colCount = Int(size.width / 2) + 1

        for col in 0..<colCount {
            let xi = CGFloat(col) * 2
            let nx = xi / size.width

            let histIdx = min(Int(nx * CGFloat(bufCount - 1)), bufCount - 1)
            let histLevel = levels[histIdx]
            let amp = min(1.0, pow(max(0, (histLevel - 0.08) / 0.62), 0.85))

            let bandHalf = size.height * (0.03 + amp * 0.45)
            let posBright: CGFloat = 0.4 + pow(nx, 0.8) * 0.3
            let levelBright: CGFloat = 0.45 + amp * 0.35

            let cr: Double = 0.82 - Double(nx) * 0.42
            let cg: Double = 0.85 - Double(nx) * 0.25
            let coreColor = Color(red: cr, green: cg, blue: 1.0)

            for j in 0..<180 {
                let h1 = hash(col, j)
                let h2 = hash(col, j &+ 53)
                let h3 = hash(col, j &+ 137)

                let scatter = (h1 - 0.5) * 2
                let py = center + scatter * abs(scatter) * bandHalf

                let freq = 3.0 + Double(h2) * 10.0
                let twinkle: CGFloat = 0.45 + 0.55 * CGFloat(sin(time * freq + Double(h3) * .pi * 2))

                let baseOp = posBright * twinkle * levelBright
                guard baseOp > 0.02 else { continue }

                let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(Double(min(1.0, baseOp)))))
            }
        }
    }

    private func hash(_ a: Int, _ b: Int) -> CGFloat {
        var h = a &* 374761393 &+ b &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return CGFloat(abs(h) % 10000) / 10000.0
    }
}

/// Frame-rate-independent exponential smoothing for audio level.
private final class LevelSmoother {
    var current: CGFloat = 0
    var target: CGFloat = 0
    private var lastTime: Double = 0
    private let timeConstant: Double

    init(timeConstant: Double = 0.8) {
        self.timeConstant = timeConstant
    }

    func update(time: Double) -> CGFloat {
        if lastTime == 0 { lastTime = time; return current }
        let dt = min(time - lastTime, 0.05)
        lastTime = time
        if timeConstant <= 0 {
            current = target
        } else {
            let alpha = CGFloat(1.0 - exp(-dt / timeConstant))
            current += (target - current) * alpha
        }
        return current
    }
}

/// Scrolling level history: newest on right, drifts left over time.
/// Index 0 = oldest (leftmost), last = newest (rightmost).
private final class LevelTimeline {
    private static let bufferSize = 200
    private var levels: [CGFloat]
    private var lastTime: Double = 0
    private var accumulator: Double = 0
    private let scrollSpeed: Double = 50  // entries shifted per second

    init() {
        levels = Array(repeating: 0, count: Self.bufferSize)
    }

    func update(time: Double, currentLevel: CGFloat) -> [CGFloat] {
        if lastTime == 0 {
            lastTime = time
            return levels
        }
        let dt = min(time - lastTime, 0.05)
        lastTime = time

        accumulator += dt * scrollSpeed
        let shift = Int(accumulator)
        if shift > 0 {
            accumulator -= Double(shift)
            let actual = min(shift, Self.bufferSize)
            levels.removeFirst(actual)
            for _ in 0..<actual {
                levels.append(currentLevel)
            }
        }
        levels[levels.count - 1] = currentLevel
        return levels
    }
}

// MARK: - Hover Tracking (works even when app is not active)

/// Uses NSTrackingArea with `.activeAlways` so hover fires on a non-key,
/// non-activating NSPanel regardless of which app is in the foreground.
struct FloatingBarHoverTracker: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

final class HoverTrackingNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var enterWorkItem: DispatchWorkItem?

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        enterWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            // Re-check mouse position at trigger time: updateTrackingAreas()
            // sends synthetic mouseEntered when the tracking area is recreated
            // with the cursor inside (e.g. bar grows during recording).
            let mouseInView = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard self.bounds.contains(mouseInView) else { return }
            self.onHoverChanged?(true)
        }
        enterWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        enterWorkItem?.cancel()
        onHoverChanged?(false)
    }
}

// MARK: - Liquid Glass Compatibility

private extension View {
    @ViewBuilder
    func floatingGlass<S: Shape>(tint: Color?, in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.tint(tint), in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }
}
