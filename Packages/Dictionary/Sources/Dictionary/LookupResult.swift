import Foundation

/// One dictionary match for scanned text: the headword, how the scanned text
/// deinflected to it, and what each enabled dictionary says about it.
public struct TermLookupResult: Equatable, Sendable {
    /// The scanned text this result covers (e.g. 食べさせられなかった).
    public var matched: String
    /// `matched` after deinflection (e.g. 食べる).
    public var deinflected: String
    public var expression: String
    public var reading: String
    /// Part-of-speech rules from the dictionary (v1, v5, adj-i…).
    public var rules: [String]
    public var score: Int
    /// Inflections applied to the headword, in Yomitan's order (base form outward):
    /// 食べさせられなかった → causative, potential or passive, negative, -た.
    public var inflections: [Inflection]
    public var preprocessorSteps: Int
    public var glossaries: [Glossary]
    public var frequencies: [FrequencyGroup]
    public var pitches: [PitchGroup]

    public init(
        matched: String, deinflected: String, expression: String, reading: String, rules: [String] = [],
        score: Int = 0, inflections: [Inflection] = [], preprocessorSteps: Int = 0, glossaries: [Glossary] = [],
        frequencies: [FrequencyGroup] = [], pitches: [PitchGroup] = []
    ) {
        self.matched = matched
        self.deinflected = deinflected
        self.expression = expression
        self.reading = reading
        self.rules = rules
        self.score = score
        self.inflections = inflections
        self.preprocessorSteps = preprocessorSteps
        self.glossaries = glossaries
        self.frequencies = frequencies
        self.pitches = pitches
    }
}

public struct Inflection: Equatable, Sendable {
    public var name: String
    public var description: String

    public init(name: String, description: String = "") {
        self.name = name
        self.description = description
    }
}

public struct Glossary: Equatable, Sendable {
    public var dictionary: String
    /// The term's Yomitan definitions as JSON (an array of strings, text, structured content or images).
    public var json: String
    public var definitionTags: [String]
    public var termTags: [String]

    public init(dictionary: String, json: String, definitionTags: [String] = [], termTags: [String] = []) {
        self.dictionary = dictionary
        self.json = json
        self.definitionTags = definitionTags
        self.termTags = termTags
    }
}

public struct Frequency: Equatable, Sendable {
    public var value: Int
    /// What the dictionary wants shown, e.g. "13390㋕" for JPDB's kana-form frequency.
    public var display: String

    public init(value: Int, display: String) {
        self.value = value
        self.display = display
    }
}

public struct FrequencyGroup: Equatable, Sendable {
    public var dictionary: String
    public var values: [Frequency]

    public init(dictionary: String, values: [Frequency]) {
        self.dictionary = dictionary
        self.values = values
    }
}

public struct PitchAccent: Equatable, Sendable {
    /// Mora after which the pitch drops; 0 is heiban (no drop).
    public var downstep: Int
    public var pattern: String?
    public var nasal: [Int]
    public var devoice: [Int]

    public init(downstep: Int, pattern: String? = nil, nasal: [Int] = [], devoice: [Int] = []) {
        self.downstep = downstep
        self.pattern = pattern
        self.nasal = nasal
        self.devoice = devoice
    }
}

public struct PitchGroup: Equatable, Sendable {
    public var dictionary: String
    public var accents: [PitchAccent]

    public init(dictionary: String, accents: [PitchAccent]) {
        self.dictionary = dictionary
        self.accents = accents
    }
}
