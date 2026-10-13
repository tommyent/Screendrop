import Foundation

/// The options for the freehand stroke pipeline.
struct StrokeOptions {
    /// Cap, taper and easing for one end of the line.
    struct End {
        var cap: Bool = true
        /// `nil` means no taper; a value tapers over that distance; `.infinity` means the whole stroke.
        var taper: Double? = nil
        var easing: ((Double) -> Double)? = nil
    }

    /// The base size (diameter) of the stroke.
    var size: Double = 16
    /// The effect of pressure on the stroke's size.
    var thinning: Double = 0.5
    /// How much to soften the stroke's edges.
    var smoothing: Double = 0.5
    /// How much to smooth the input points towards each other.
    var streamline: Double = 0.5
    /// An easing function applied to each point's pressure.
    var easing: (Double) -> Double = { $0 }
    /// Whether to simulate pressure from velocity.
    var simulatePressure: Bool = true
    var start = End()
    var end = End()
    /// Whether to handle the points as a completed stroke.
    var last: Bool = false
}

/// Resolve a taper option to a distance.
func resolveTaper(_ taper: Double?, _ size: Double, _ totalLength: Double) -> Double {
    guard let taper, taper != 0 else { return 0 }
    return taper.isInfinite ? Swift.max(size, totalLength) : taper
}

/// The freehand settings used for the draw shape.
enum FreehandSettings {
    /// A finished freehand stroke's points, eased once so hand jitter the
    /// live streamline lets through doesn't stay in the saved line: two
    /// passes of a 1-2-3-2-1 moving average, the ends kept where they were
    /// drawn, pressure (z) averaged with them.
    static func smoothedPoints(_ points: [Vec]) -> [Vec] {
        guard points.count > 4 else { return points }
        let weights: [Double] = [1, 2, 3, 2, 1]
        var current = points
        for _ in 0..<2 {
            var next = current
            for index in 1..<(current.count - 1) {
                var x = 0.0, y = 0.0, z = 0.0, total = 0.0
                for (offset, weight) in zip(-2...2, weights) {
                    let neighbour = current[min(max(index + offset, 0), current.count - 1)]
                    x += neighbour.x * weight; y += neighbour.y * weight; z += neighbour.z * weight
                    total += weight
                }
                next[index] = Vec(x / total, y / total, z / total)
            }
            current = next
        }
        return current
    }

    /// `(t) => t * 0.65 + SIN((t * PI) / 2) * 0.35`
    static let penEasing: (Double) -> Double = { t in t * 0.65 + sin((t * PI) / 2) * 0.35 }

    static func simulatePressure(_ strokeWidth: Double) -> StrokeOptions {
        StrokeOptions(
            size: strokeWidth,
            thinning: 0.5,
            smoothing: 0.70,
            streamline: modulate(strokeWidth, (9, 16), (0.80, 0.88), true),
            easing: Easings.easeOutSine,
            simulatePressure: true
        )
    }

    static func realPressure(_ strokeWidth: Double) -> StrokeOptions {
        StrokeOptions(
            size: 1 + strokeWidth * 1.2,
            thinning: 0.62,
            smoothing: 0.70,
            streamline: 0.78,
            easing: penEasing,
            simulatePressure: false
        )
    }

    static func solid(_ strokeWidth: Double) -> StrokeOptions {
        StrokeOptions(
            size: strokeWidth,
            thinning: 0,
            smoothing: 0.70,
            streamline: modulate(strokeWidth, (9, 16), (0.80, 0.88), true),
            easing: Easings.linear,
            simulatePressure: false
        )
    }

    static func solidRealPressure(_ strokeWidth: Double) -> StrokeOptions {
        StrokeOptions(
            size: strokeWidth,
            thinning: 0,
            smoothing: 0.70,
            streamline: 0.78,
            easing: Easings.linear,
            simulatePressure: false
        )
    }

    /// The options for a draw shape.
    /// `forceSolid` is what the geometry (hit-testing) pass uses: an even-width centerline.
    static func forDrawShape(
        isPen: Bool,
        isComplete: Bool,
        strokeWidth: Double,
        forceComplete: Bool,
        forceSolid: Bool
    ) -> StrokeOptions {
        let last = isComplete || forceComplete
        var options: StrokeOptions
        if forceSolid {
            options = isPen ? solidRealPressure(strokeWidth) : solid(strokeWidth)
        } else if isPen {
            options = realPressure(strokeWidth)
        } else {
            options = simulatePressure(strokeWidth)
        }
        options.last = last
        return options
    }
}
