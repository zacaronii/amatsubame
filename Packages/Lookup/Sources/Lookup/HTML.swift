import Foundation

enum HTML {
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// `someKey` → `some-key`, as the DOM dataset API maps names to attributes.
    static func kebab(_ name: String) -> String {
        var result = ""
        for character in name {
            if character.isUppercase {
                result += "-" + character.lowercased()
            } else {
                result.append(character)
            }
        }
        return result
    }
}
