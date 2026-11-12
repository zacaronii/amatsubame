import Foundation

public enum DictionaryError: Error, Equatable, LocalizedError {
    case importFailed(String)
    /// The zip has no entries (only its index), as a broken release can be.
    case empty
    case alreadyInstalled(title: String, revision: String?)
    case unreadable(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .importFailed(let reason): "Couldn't import the dictionary. \(reason)"
        case .empty: "The dictionary has no entries."
        case .alreadyInstalled(let title, let revision):
            "\(title) \(revision.map { "(\($0)) " } ?? "")is already installed."
        case .unreadable(let title): "\(title) couldn't be loaded. Try deleting and re-importing it."
        case .notFound: "That dictionary isn't installed."
        }
    }
}
