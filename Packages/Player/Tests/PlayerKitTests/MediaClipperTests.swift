import Foundation
import Testing
@testable import PlayerKit

@Suite struct MediaClipperTests {
    /// The note x264 writes into its first frame (an SEI), here as in Kill la Kill's 4:4:4 special.
    @Test func readsTheX264BuildFromItsNote() {
        let note = Array("\u{5}\u{ff}x264 - core 140 r2377 1ca7bb9 - H.264/MPEG-4 AVC codec - options: 8x8dct=1".utf8)
        #expect(note.withUnsafeBufferPointer { MediaClipper.x264Build(in: $0) } == 140)
    }

    @Test func noNoteMeansNoBuild() {
        let other = Array("Lavc60.3.100 libx265 - core".utf8), cut = Array("x264 - core ".utf8)
        #expect(other.withUnsafeBufferPointer { MediaClipper.x264Build(in: $0) } == nil)
        #expect(cut.withUnsafeBufferPointer { MediaClipper.x264Build(in: $0) } == nil)
        #expect([UInt8]().withUnsafeBufferPointer { MediaClipper.x264Build(in: $0) } == nil)
    }
}
