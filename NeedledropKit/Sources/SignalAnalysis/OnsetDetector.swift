/// Peak-picks spectral flux against an adaptive threshold (mean of the last ~0.5 s).
/// Reports with one hop of latency, since a peak is only known once the next value falls.
struct OnsetDetector {
    let hopDuration: Double
    var multiplier: Float = 1.5
    var delta: Float = 0.01
    var minimumInterval: Double = 0.06

    private var history: [Float]
    private var index = 0
    private var filled = 0
    private var sum: Float = 0
    private var previous1: Float = 0
    private var previous2: Float = 0
    private(set) var lastOnsetTime = -Double.infinity

    init(hopDuration: Double, window: Double = 0.5) {
        self.hopDuration = hopDuration
        history = Array(repeating: 0, count: max(4, Int(window / hopDuration)))
    }

    /// Returns the onset time if the previous hop was an onset.
    mutating func process(flux: Float, time: Double) -> Double? {
        let mean = filled > 0 ? sum / Float(filled) : 0
        let candidate = previous1
        let candidateTime = time - hopDuration
        var result: Double?
        if candidate > previous2, candidate >= flux,
           candidate > mean * multiplier + delta,
           candidateTime - lastOnsetTime >= minimumInterval {
            lastOnsetTime = candidateTime
            result = candidateTime
        }

        sum += flux - history[index]
        history[index] = flux
        index = (index + 1) % history.count
        filled = min(filled + 1, history.count)
        previous2 = previous1
        previous1 = flux
        return result
    }
}
