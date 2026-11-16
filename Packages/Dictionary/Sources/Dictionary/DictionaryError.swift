import Foundation

public enum DictionaryError: Error, Equatable, LocalizedError {
    case importFailed(String)
    /// The zip has no entries (only its index), as a broken release can be.
    case empty
    case alreadyInstalled(title: String, revision: String?)
    case notFound
    /// Made by a newer hoshidicts than the app's (`DictionaryFormat.newer`).
    case newerFormat

    public var errorDescription: String? {
        switch self {
        case .importFailed(let reason): "Couldn't import the dictionary. \(reason)"
        case .empty: "The dictionary has no entries."
        case .alreadyInstalled(let title, let revision):
            "\(title) \(revision.map { "(\($0)) " } ?? "")is already installed."
        case .notFound: "That dictionary isn't installed."
        case .newerFormat: "This dictionary was made by a newer version of hoshidicts. Update the app to use it."
        }
    }
}
