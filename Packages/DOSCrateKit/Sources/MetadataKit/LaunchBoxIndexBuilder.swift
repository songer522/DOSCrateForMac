import Foundation

public enum LaunchBoxIndexBuilder {
    public static func build(xml: URL) throws -> [LaunchBoxRecord] {
        guard let stream = InputStream(url: xml) else {
            throw LaunchBoxError.parse("Could not open XML stream at \(xml.path)")
        }
        let parser = XMLParser(stream: stream)
        let delegate = BuilderDelegate()
        parser.delegate = delegate
        let ok = parser.parse()
        if !ok || !delegate.sawRoot {
            let reason = parser.parserError?.localizedDescription ?? "Malformed LaunchBox XML"
            throw LaunchBoxError.parse(reason)
        }
        return delegate.finalizeRecords()
    }
}

private final class BuilderDelegate: NSObject, XMLParserDelegate {
    private enum Section {
        case none
        case game
        case alternateName
        case image
    }

    var sawRoot = false
    private var section: Section = .none
    private var currentElement: String?
    private var buffer: String = ""

    private var fields: [String: String] = [:]
    private var games: [LaunchBoxRecord] = []
    private var alternateNamesByID: [Int: [String]] = [:]
    private var imagesByID: [Int: [LaunchBoxImage]] = [:]

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "LaunchBox" {
            sawRoot = true
            return
        }
        switch section {
        case .none:
            switch elementName {
            case "Game":
                section = .game
                fields.removeAll(keepingCapacity: true)
            case "GameAlternateName":
                section = .alternateName
                fields.removeAll(keepingCapacity: true)
            case "GameImage":
                section = .image
                fields.removeAll(keepingCapacity: true)
            default:
                break
            }
        case .game, .alternateName, .image:
            currentElement = elementName
            buffer.removeAll(keepingCapacity: true)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil else { return }
        buffer.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch section {
        case .none:
            break
        case .game:
            if elementName == "Game" {
                finishGame()
                section = .none
            } else if currentElement == elementName {
                fields[elementName] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                currentElement = nil
            }
        case .alternateName:
            if elementName == "GameAlternateName" {
                finishAlternateName()
                section = .none
            } else if currentElement == elementName {
                fields[elementName] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                currentElement = nil
            }
        case .image:
            if elementName == "GameImage" {
                finishImage()
                section = .none
            } else if currentElement == elementName {
                fields[elementName] = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                currentElement = nil
            }
        }
    }

    private func finishGame() {
        guard fields["Platform"] == "MS-DOS",
              let idText = fields["DatabaseID"],
              let id = Int(idText),
              let name = fields["Name"],
              !name.isEmpty
        else { return }

        let year: Int? = {
            if let yText = fields["ReleaseYear"], let y = Int(yText) {
                return y
            }
            if let dText = fields["ReleaseDate"], dText.count >= 4, let y = Int(dText.prefix(4)) {
                return y
            }
            return nil
        }()

        let genres = (fields["Genres"] ?? "")
            .split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        func nonEmpty(_ key: String) -> String? {
            guard let v = fields[key], !v.isEmpty else { return nil }
            return v
        }

        games.append(
            LaunchBoxRecord(
                id: id,
                name: name,
                releaseYear: year,
                developer: nonEmpty("Developer"),
                publisher: nonEmpty("Publisher"),
                genres: genres,
                overview: nonEmpty("Overview")
            )
        )
    }

    private func finishAlternateName() {
        guard let idText = fields["DatabaseID"],
              let id = Int(idText),
              let alt = fields["AlternateName"],
              !alt.isEmpty
        else { return }
        alternateNamesByID[id, default: []].append(alt)
    }

    private func finishImage() {
        guard let idText = fields["DatabaseID"],
              let id = Int(idText),
              let fileName = fields["FileName"],
              !fileName.isEmpty,
              let type = fields["Type"],
              !type.isEmpty
        else { return }
        let region: String? = {
            guard let r = fields["Region"], !r.isEmpty else { return nil }
            return r
        }()
        imagesByID[id, default: []].append(LaunchBoxImage(type: type, fileName: fileName, region: region))
    }

    func finalizeRecords() -> [LaunchBoxRecord] {
        games.map { record in
            var copy = record
            copy.alternateNames = alternateNamesByID[record.id] ?? []
            copy.images = imagesByID[record.id] ?? []
            return copy
        }
    }
}
