import SwiftUI
import AppKit

/// v6 `UnifiedBars` glyph — three vertical bars that share the same geometry
/// across all three notch states (idle / running / waiting), so transitions
/// animate bar heights smoothly instead of swapping glyphs.
///
/// Canonical geometry (from the design handoff): 24×24 box, 3 bars of width
/// 2.5 centered on columns x = 5.25 / 10.75 / 16.25, rounded to a pill.
struct UnifiedBars: View {
    enum Mode: Equatable {
        case idle       // rest — 3 short bars, middle breathes
        case running    // wave — heights 4→12→4, stagger 0.15s
        case waiting    // pause — outer bars tall, middle hidden, cross-pulse
    }

    var mode: Mode
    var size: CGFloat = 24
    var animates: Bool = false
    var frameInterval: TimeInterval = 1.0 / 12.0
    /// Ink color for bars / tick. Defaults to the v6 paper ink.
    var tint: Color = Color(red: 0xf1 / 255.0, green: 0xea / 255.0, blue: 0xd9 / 255.0)

    private static let box: CGFloat = 24
    private static let barWidth: CGFloat = 2.5
    private static let center: CGFloat = 12

    private static let columns: [Column] = [
        Column(x: 5.25,  idleH: 3, waveCycle: [4, 12, 4], waveDelay: 0.00, waitH: 10),
        Column(x: 10.75, idleH: 5, waveCycle: [6, 14, 6], waveDelay: 0.15, waitH: 0),
        Column(x: 16.25, idleH: 3, waveCycle: [4, 10, 4], waveDelay: 0.30, waitH: 10),
    ]

    var body: some View {
        Group {
            if shouldAnimate {
                AnimatedUnifiedBars(mode: mode, size: size, tint: tint)
            } else {
                barsCanvas(time: 0)
            }
        }
        .frame(width: size, height: size)
    }

    private var shouldAnimate: Bool {
        animates && mode != .idle
    }

    private func barsCanvas(time: TimeInterval) -> some View {
        Canvas { context, canvasSize in
            withScaledContext(context, canvasSize) { ctx in
                drawBars(context: ctx, time: time)
            }
        }
    }

    // MARK: - Drawing

    private func withScaledContext(
        _ context: GraphicsContext,
        _ canvasSize: CGSize,
        body: (GraphicsContext) -> Void
    ) {
        var ctx = context
        let side = min(canvasSize.width, canvasSize.height)
        let scale = side / Self.box
        let dx = (canvasSize.width - side) / 2
        let dy = (canvasSize.height - side) / 2
        ctx.translateBy(x: dx, y: dy)
        ctx.scaleBy(x: scale, y: scale)
        body(ctx)
    }

    private func drawBars(context: GraphicsContext, time: TimeInterval) {
        for column in Self.columns {
            let (height, y, opacity) = barGeometry(for: column, time: time)
            guard opacity > 0, height > 0 else { continue }
            let rect = CGRect(
                x: column.x,
                y: y,
                width: Self.barWidth,
                height: height
            )
            let path = Path(
                roundedRect: rect,
                cornerSize: CGSize(width: Self.barWidth / 2, height: Self.barWidth / 2)
            )
            context.fill(path, with: .color(tint.opacity(opacity)))
        }
    }

    private func barGeometry(
        for column: Column,
        time: TimeInterval
    ) -> (height: CGFloat, y: CGFloat, opacity: Double) {
        switch mode {
        case .idle:
            let h = column.idleH
            let isMiddle = column.x == Self.columns[1].x
            let breath = isMiddle
                ? 0.7 + 0.3 * abs(sin(time * 2 * .pi / 2.8))
                : 1.0
            return (h, Self.center - h / 2, breath)
        case .running:
            let cycle = column.waveCycle
            let period: TimeInterval = 0.9
            let raw = (time - column.waveDelay)
                .truncatingRemainder(dividingBy: period) / period
            let phase = raw < 0 ? raw + 1 : raw
            let h: CGFloat
            if phase < 0.5 {
                let t = phase / 0.5
                h = cycle[0] + (cycle[1] - cycle[0]) * t
            } else {
                let t = (phase - 0.5) / 0.5
                h = cycle[1] + (cycle[2] - cycle[1]) * t
            }
            return (h, Self.center - h / 2, 1.0)
        case .waiting:
            let h = column.waitH
            guard h > 0 else { return (0, Self.center, 0) }
            let isLeading = column.x < Self.center
            let period: TimeInterval = 1.8
            let offset = isLeading ? 0.0 : period / 2
            let progress = ((time + offset)
                .truncatingRemainder(dividingBy: period)) / period
            let wave = 0.5 - 0.5 * cos(progress * 2 * .pi)
            let opacity = 0.55 + 0.45 * wave
            return (h, Self.center - h / 2, opacity)
        }
    }

    private struct Column: Equatable {
        let x: CGFloat
        let idleH: CGFloat
        let waveCycle: [CGFloat]
        let waveDelay: TimeInterval
        let waitH: CGFloat
    }
}

private struct AnimatedUnifiedBars: NSViewRepresentable {
    let mode: UnifiedBars.Mode
    let size: CGFloat
    let tint: Color

    func makeNSView(context: Context) -> UnifiedBarsLayerView {
        let view = UnifiedBarsLayerView()
        view.update(mode: mode, size: size, tint: tint)
        return view
    }

    func updateNSView(_ nsView: UnifiedBarsLayerView, context: Context) {
        nsView.update(mode: mode, size: size, tint: tint)
    }
}

private final class UnifiedBarsLayerView: NSView {
    private struct Column {
        let x: CGFloat
        let idleH: CGFloat
        let waveCycle: [CGFloat]
        let waveDelay: TimeInterval
        let waitH: CGFloat
    }

    private static let box: CGFloat = 24
    private static let barWidth: CGFloat = 2.5
    private static let center: CGFloat = 12
    private static let columns: [Column] = [
        Column(x: 5.25,  idleH: 3, waveCycle: [4, 12, 4], waveDelay: 0.00, waitH: 10),
        Column(x: 10.75, idleH: 5, waveCycle: [6, 14, 6], waveDelay: 0.20, waitH: 0),
        Column(x: 16.25, idleH: 3, waveCycle: [4, 10, 4], waveDelay: 0.40, waitH: 10),
    ]

    private var barLayers: [CALayer] = []
    private var currentMode: UnifiedBars.Mode?
    private var currentSize: CGFloat = 0
    private var currentTintDescription: String = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.isGeometryFlipped = true
        barLayers = Self.columns.map { _ in CALayer() }
        for barLayer in barLayers {
            barLayer.masksToBounds = true
            layer?.addSublayer(barLayer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(mode: UnifiedBars.Mode, size: CGFloat, tint: Color) {
        let tintDescription = "\(tint)"
        let cgColor = NSColor(tint).cgColor
        for barLayer in barLayers {
            barLayer.backgroundColor = cgColor
        }

        guard currentMode != mode
            || currentSize != size
            || currentTintDescription != tintDescription else {
            return
        }

        currentMode = mode
        currentSize = size
        currentTintDescription = tintDescription
        configureBars(mode: mode, size: size)
    }

    override func layout() {
        super.layout()
        guard let currentMode else { return }
        configureBars(mode: currentMode, size: currentSize)
    }

    private func configureBars(mode: UnifiedBars.Mode, size: CGFloat) {
        let scale = max(0.01, size / Self.box)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, column) in Self.columns.enumerated() {
            let barLayer = barLayers[index]
            barLayer.removeAllAnimations()
            barLayer.cornerRadius = (Self.barWidth * scale) / 2

            switch mode {
            case .idle:
                applyGeometry(to: barLayer, column: column, height: column.idleH, scale: scale)
                barLayer.opacity = Float(column.x == Self.columns[1].x ? 0.86 : 1.0)
            case .running:
                applyGeometry(to: barLayer, column: column, height: column.waveCycle[0], scale: scale)
                barLayer.opacity = 1.0
                addRunningAnimation(to: barLayer, column: column, scale: scale)
            case .waiting:
                guard column.waitH > 0 else {
                    applyGeometry(to: barLayer, column: column, height: 0, scale: scale)
                    barLayer.opacity = 0
                    continue
                }
                applyGeometry(to: barLayer, column: column, height: column.waitH, scale: scale)
                barLayer.opacity = 0.55
                addWaitingAnimation(to: barLayer, column: column)
            }
        }
        CATransaction.commit()
    }

    private func applyGeometry(to layer: CALayer, column: Column, height: CGFloat, scale: CGFloat) {
        let width = Self.barWidth * scale
        let scaledHeight = height * scale
        layer.bounds = CGRect(x: 0, y: 0, width: width, height: scaledHeight)
        layer.position = CGPoint(
            x: (column.x + Self.barWidth / 2) * scale,
            y: Self.center * scale
        )
    }

    private func addRunningAnimation(to layer: CALayer, column: Column, scale: CGFloat) {
        let animation = CAKeyframeAnimation(keyPath: "bounds.size.height")
        animation.values = column.waveCycle.map { $0 * scale }
        animation.keyTimes = [0, 0.5, 1]
        animation.duration = 1.55
        animation.beginTime = CACurrentMediaTime() + column.waveDelay
        animation.repeatCount = .infinity
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        layer.add(animation, forKey: "openIsland.runningHeight")
    }

    private func addWaitingAnimation(to layer: CALayer, column: Column) {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0.55, 1.0, 0.55]
        animation.keyTimes = [0, 0.5, 1]
        animation.duration = 2.4
        animation.beginTime = CACurrentMediaTime() + (column.x < Self.center ? 0 : 1.2)
        animation.repeatCount = .infinity
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        layer.add(animation, forKey: "openIsland.waitingOpacity")
    }
}
