/// Notices when a source claims to be running but no audio is arriving (a wedged engine
/// after a driver hiccup, an interface that stopped clocking). Pure: fed wall-clock and
/// audio time, it says when to restart.
public struct StallDetector: Sendable {
    public var timeout: Double
    /// After a restart, wait this long before calling another.
    public var backoff: Double

    private var lastAudioTime: Double?
    private var lastAdvance: Double?
    private var lastRestart = -Double.infinity

    public init(timeout: Double = 5, backoff: Double = 20) {
        self.timeout = timeout
        self.backoff = backoff
    }

    /// Returns true when the input should be restarted now.
    public mutating func update(now: Double, audioTime: Double, running: Bool) -> Bool {
        guard running else {
            lastAudioTime = nil
            lastAdvance = nil
            return false
        }
        if audioTime != lastAudioTime {
            lastAudioTime = audioTime
            lastAdvance = now
            return false
        }
        guard let since = lastAdvance, now - since >= timeout, now - lastRestart >= backoff else { return false }
        lastRestart = now
        lastAdvance = now
        return true
    }
}
