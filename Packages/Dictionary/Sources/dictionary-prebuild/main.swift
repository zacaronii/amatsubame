import Dictionary
import Foundation

// Prebuilds Yomitan zips for the Safari extension (see DictionaryLibrary.prebuild):
//   dictionary-prebuild <output folder> <zip>...
// Writes <output>/<zip name>.hoshidict, skipping zips unchanged since the last run, and
// removes packages for zips no longer listed.
let arguments = CommandLine.arguments.dropFirst()
guard let outputPath = arguments.first, arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: dictionary-prebuild <output folder> <zip>...\n".utf8))
    exit(2)
}
let output = URL(filePath: outputPath, directoryHint: .isDirectory)
let fileManager = FileManager.default
try fileManager.createDirectory(at: output, withIntermediateDirectories: true)
var wanted: Set<String> = []
for path in arguments.dropFirst() {
    let zip = URL(filePath: path)
    let name = zip.deletingPathExtension().lastPathComponent + ".hoshidict"
    wanted.insert(name)
    let package = output.appending(path: name, directoryHint: .isDirectory)
    let attributes = try fileManager.attributesOfItem(atPath: zip.path(percentEncoded: false))
    let stamp = "\(attributes[.size] ?? 0) \((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    let stampFile = package.appending(path: "source.txt")
    if (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp {
        print("up to date: \(name)")
        continue
    }
    let started = Date()
    try DictionaryLibrary.prebuild(zip: zip, into: package)
    try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
    print(String(format: "prebuilt: %@ (%.1f s)", name, Date().timeIntervalSince(started)))
}
for name in (try? fileManager.contentsOfDirectory(atPath: output.path(percentEncoded: false))) ?? []
where name.hasSuffix(".hoshidict") && !wanted.contains(name) {
    try? fileManager.removeItem(at: output.appending(path: name))
}
