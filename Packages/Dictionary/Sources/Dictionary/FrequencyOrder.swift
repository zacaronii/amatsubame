import CHoshiDicts

/// Which way the sort frequency dictionary's numbers run. Yomitan's (and Hachidori's) rule:
/// a rank (1 is the most common, or no `frequencyMode`) sorts ascending; an occurrence count
/// sorts descending. hoshidicts' AUTO uses no sort dictionary at all, so one is always given.
public enum FrequencyOrder: String, Sendable {
    case ascending, descending

    /// From a dictionary's `index.json` `frequencyMode`.
    public init(frequencyMode: String?) {
        self = frequencyMode == "occurrence-based" ? .descending : .ascending
    }

    /// Hachidori's `frequencyOrder` setting, when it names a direction ("auto" and "disabled" don't).
    public init?(hostSetting: String) {
        switch hostSetting {
        case "ascending": self = .ascending
        case "descending": self = .descending
        default: return nil
        }
    }

    var hoshidicts: Int32 {
        Int32((self == .ascending ? HD_LOOKUP_FREQUENCY_ORDER_ASCENDING : HD_LOOKUP_FREQUENCY_ORDER_DESCENDING).rawValue)
    }
}
