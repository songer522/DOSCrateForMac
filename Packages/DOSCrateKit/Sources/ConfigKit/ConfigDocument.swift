import Foundation

/// An ordered DOSBox-style config: `[section]` blocks of `key = value`, plus verbatim `[autoexec]` lines.
public struct ConfigDocument: Equatable, Sendable {
    typealias Section = (name: String, entries: [(key: String, value: String)])

    var sections: [Section] = []
    public var autoexec: [String] = []

    public init() {}

    public static func == (a: ConfigDocument, b: ConfigDocument) -> Bool {
        a.autoexec == b.autoexec && a.sections.count == b.sections.count
            && zip(a.sections, b.sections).allSatisfy { x, y in
                norm(x.name) == norm(y.name) && x.entries.count == y.entries.count
                    && zip(x.entries, y.entries).allSatisfy { norm($0.key) == norm($1.key) && $0.value == $1.value }
            }
    }

    private static func norm(_ identifier: String) -> String {
        identifier.trimmingCharacters(in: .whitespaces).lowercased()
    }

    public mutating func set(_ section: String, _ key: String, _ value: String) {
        let normSection = Self.norm(section)
        let normKey = Self.norm(key)
        if let s = sections.firstIndex(where: { Self.norm($0.name) == normSection }) {
            if let e = sections[s].entries.firstIndex(where: { Self.norm($0.key) == normKey }) {
                sections[s].entries[e].value = value
            } else {
                sections[s].entries.append((normKey, value))
            }
        } else {
            sections.append((normSection, [(normKey, value)]))
        }
    }

    public func value(_ section: String, _ key: String) -> String? {
        let normSection = Self.norm(section)
        let normKey = Self.norm(key)
        return sections.first { Self.norm($0.name) == normSection }?
            .entries.first { Self.norm($0.key) == normKey }?.value
    }

    /// The higher document's keys win and its autoexec lines are appended.
    public mutating func merge(_ higher: ConfigDocument) {
        for s in higher.sections {
            for e in s.entries { set(s.name, e.key, e.value) }
        }
        autoexec += higher.autoexec
    }

    public func render() -> String {
        var blocks: [String] = []
        for s in sections where !s.entries.isEmpty {
            blocks.append("[\(s.name)]\n" + s.entries.map { "\($0.key) = \($0.value)\n" }.joined())
        }
        if !autoexec.isEmpty {
            blocks.append("[autoexec]\n" + autoexec.map { $0 + "\n" }.joined())
        }
        return blocks.joined(separator: "\n")
    }

    public static func parse(_ text: String) -> ConfigDocument {
        var doc = ConfigDocument()
        var section = ""
        for substring in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let raw = String(substring)
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if section == "autoexec", !(line.hasPrefix("[") && line.hasSuffix("]")) {
                doc.autoexec.append(raw)
                continue
            }
            if line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                continue
            }
            guard let eq = line.firstIndex(of: "="), !section.isEmpty else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { doc.set(section, key, value) }
        }
        return doc
    }
}

public struct ConfigEnvironment: Sendable {
    public var soundfontPath: String?
    public var mt32RomDir: String?
    public init(soundfontPath: String? = nil, mt32RomDir: String? = nil) {
        self.soundfontPath = soundfontPath
        self.mt32RomDir = mt32RomDir
    }
}
