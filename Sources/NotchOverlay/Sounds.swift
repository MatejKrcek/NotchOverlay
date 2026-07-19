import AVFoundation

/// 8-bit zvuky syntetizované jako čtvercová vlna — žádné assety.
final class Sounds {
    static let shared = Sounds()

    var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "soundsEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "soundsEnabled") }
    }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate = 44_100.0
    private var started = false

    private func startIfNeeded() {
        guard !started else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0.18
        do {
            try engine.start()
            player.play()
            started = true
        } catch {
            // bez audio výstupu prostě mlčíme
        }
    }

    /// Sekvence (frekvence Hz, délka s); freq 0 = pauza.
    private func play(_ notes: [(Double, Double)]) {
        guard enabled else { return }
        startIfNeeded()
        guard started else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let total = notes.reduce(0) { $0 + $1.1 }
        let frames = AVAudioFrameCount(total * sampleRate)
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buf.frameLength = frames
        let data = buf.floatChannelData![0]
        var i = 0
        for (freq, dur) in notes {
            let n = Int(dur * sampleRate)
            for j in 0..<n {
                if freq == 0 { data[i] = 0 }
                else {
                    let phase = Double(j) * freq / sampleRate
                    let square: Float = phase.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : -1
                    // krátký decay ať to necvaká
                    let env = Float(min(1, 8 * (1 - Double(j) / Double(n))))
                    data[i] = square * 0.25 * env
                }
                i += 1
            }
        }
        player.scheduleBuffer(buf, completionHandler: nil)
    }

    func sessionStart() { play([(660, 0.06), (880, 0.08)]) }
    func permission()   { play([(880, 0.09), (0, 0.05), (880, 0.09)]) }
    func question()     { play([(523, 0.07), (659, 0.07), (784, 0.1)]) }
    func done()         { play([(523, 0.07), (784, 0.12)]) }
    func denied()       { play([(220, 0.1), (196, 0.14)]) }
}
