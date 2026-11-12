import AVFoundation

/// A short two-note chime that confirms a mark made without looking (AirPods, the car). It
/// plays through the episode's audio session, so it reaches the headphones and isn't silenced
/// by the ring switch the way system sounds are.
@MainActor
enum MarkChime {
    private static var player: AVAudioPlayer?

    static func play() {
        if player == nil {
            player = try? AVAudioPlayer(data: wav())
            player?.volume = 0.5
        }
        player?.currentTime = 0
        player?.play()
    }

    /// 16-bit mono WAV: E6 then A6, each note fading out.
    private static func wav() -> Data {
        let rate = 44_100
        var samples: [Int16] = []
        for (frequency, seconds) in [(1318.5, 0.09), (1760.0, 0.16)] {
            let count = Int(Double(rate) * seconds)
            for index in 0..<count {
                let time = Double(index) / Double(rate)
                let envelope = min(1, Double(index) / 200) * (1 - Double(index) / Double(count))
                samples.append(Int16(sin(2 * .pi * frequency * time) * envelope * 0.6 * Double(Int16.max)))
            }
        }
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(rate)); append(UInt32(rate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(bytes))
        for sample in samples { append(sample) }
        return data
    }
}
