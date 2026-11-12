// Finds black flashes in a screen recording of the reader:
//   swift scripts/analyze-page-turns.swift <recording.mov>
// Each frame is scaled to 200 columns; a column is "black" when 95% of its middle band is near
// black. The usual count (letterboxing) is the most common one; frames with clearly more black
// columns than that, while not the whole screen, are reported as flashes.
import AVFoundation
import CoreGraphics
import Foundation

let url = URL(filePath: CommandLine.arguments[1])
let asset = AVURLAsset(url: url)
let duration = try await asset.load(.duration).seconds
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: 200, height: 400)

func blackColumns(_ image: CGImage) -> Int {
    let width = image.width, height = image.height
    var pixels = [UInt8](repeating: 0, count: width * height)
    let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let top = height / 5, bottom = height * 4 / 5
    var count = 0
    for x in 0..<width {
        var dark = 0
        for y in top..<bottom where pixels[y * width + x] < 24 { dark += 1 }
        if Double(dark) >= Double(bottom - top) * 0.95 { count += 1 }
    }
    return count
}

var samples: [(time: Double, black: Int)] = []
let step = 1.0 / 30
var time = 0.0
while time < duration {
    if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
        samples.append((time, blackColumns(image)))
    }
    time += step
}
let counts = Dictionary(grouping: samples.map(\.black), by: { $0 }).mapValues(\.count)
let usual = counts.max { $0.value < $1.value }?.key ?? 0
let flashes = samples.filter { $0.black > usual + 8 && $0.black < 190 }
print("frames: \(samples.count), usual black columns: \(usual) of 200")
print("flash frames: \(flashes.count)")
var last = -1.0
for flash in flashes where flash.time - last > 0.2 {
    print(String(format: "  %.2f s: %d black columns", flash.time, flash.black))
    last = flash.time
}
