import Darwin
import Foundation

/// Заполняет только word/document.xml. Word, Python и сеть приложению не нужны.
public enum MeetingDOCXExporter {
    static let wordNamespace = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"
    static let instructions: Set<String> = [
        "Карточка участника — повторить для каждого приглашенного.",
        "Карточка вопроса — повторить для каждого пункта повестки, включая добавленные во время встречи.",
        "Карточка решения — повторить для каждого явно принятого решения.",
        "Карточка поручения — повторить для каждой отдельной задачи.",
        "Карточка открытого вопроса — повторить при необходимости.",
        "Карточка говорящего — повторить для каждого голоса на записи. Неизвестные голоса обозначать «Говорящий 1», «Говорящий 2» и далее.",
        "Привести все реплики по порядку от начала до конца доступной записи, без сокращений и пересказа. Сохранить повторы, оговорки, незавершенные фразы и слова-паразиты. Пунктуация допустима для читаемости; исправлять смысл и грамматику говорящего нельзя.",
        "Блок реплики — повторить для каждой реплики. При смене говорящего начинать новый блок. Для длинной реплики разрешены дополнительные абзацы без сокращения текста.",
        "Обозначения в тексте: [неразборчиво, таймкод]; [говорят одновременно, таймкод]; [пауза]; [смех]; [запись прервана, таймкод]; [фрагмент отсутствует, интервал]. Использовать только подтвержденные записью отметки; эмоции и мотивы не домысливать.",
        "Если точного таймкода нет, писать «таймкод не указан» и сохранять последовательную нумерацию реплик. Таймкоды не придумывать. Если исходная запись неполная, прямо указать это в разделе 9; обработку всех доступных файлов не выдавать за запись всей встречи.",
    ]

    public static func export(_ data: MeetingMinutesData, to output: URL, templateDirectory: URL? = nil) throws {
        let directory = try templateDirectory ?? MeetingTemplate.directory()
        let groups = try MeetingTemplate.groups(in: directory)
        try MeetingTemplate.validate(data, groups: groups)
        // Проверяем байты ДО распаковки: посторонний ZIP не может писать за границы временной папки.
        let original = try MeetingTemplate.verifiedFile("template.docx", in: directory)
        guard output.isFileURL, output.pathExtension.lowercased() == "docx" else {
            throw MeetingTemplateError.invalidOutput
        }
        let parent = output.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0, (parentInfo.st_mode & S_IFMT) == S_IFDIR else {
            throw MeetingTemplateError.invalidOutput
        }
        let destination = parent.appendingPathComponent(output.lastPathComponent)
        var info = stat()
        guard lstat(destination.path, &info) != 0, errno == ENOENT else {
            throw MeetingTemplateError.outputExists
        }
        var pattern = Array(parent.appendingPathComponent(".iriz-meeting-XXXXXX").path.utf8CString)
        guard let created = mkdtemp(&pattern) else { throw MeetingTemplateError.invalidOutput }
        let work = URL(fileURLWithPath: String(cString: created), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("template.docx")
        try writePrivate(original, to: archive)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try ditto(["-x", "-k", archive.path, unpacked.path])
        let documentURL = unpacked.appendingPathComponent("word/document.xml")
        let raw = try MeetingTemplate.regularFile(documentURL, limit: 2_000_000)
        let filled = try fillDocument(raw, data: data, groups: groups)
        // Распакованный файл принадлежит только этой операции; эталон не открывается на запись.
        try filled.write(to: documentURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: documentURL.path)
        let result = work.appendingPathComponent("result.docx")
        try ditto(["-c", "-k", "--norsrc", "--noextattr", "--noacl", unpacked.path, result.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: result.path)
        // link(2) атомарно отказывает, если имя заняли после первоначальной проверки.
        guard link(result.path, destination.path) == 0 else {
            throw errno == EEXIST ? MeetingTemplateError.outputExists : MeetingTemplateError.invalidOutput
        }
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw MeetingTemplateError.invalidOutput }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
    }

    private static func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "DITTOABORT": "1", "DITTONORSRC": "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { throw MeetingTemplateError.archiveFailed }
        if finished.wait(timeout: .now() + 60) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            throw MeetingTemplateError.archiveFailed
        }
        guard process.terminationStatus == 0 else { throw MeetingTemplateError.archiveFailed }
    }

    static func textNodes(_ node: XMLNode) -> [XMLElement] {
        var result: [XMLElement] = []
        if let element = node as? XMLElement, element.localName == "t", element.uri == wordNamespace {
            result.append(element)
        }
        for child in node.children ?? [] { result.append(contentsOf: textNodes(child)) }
        return result
    }

    static func text(_ node: XMLNode) -> String { textNodes(node).map { $0.stringValue ?? "" }.joined() }

    static func fillDocument(_ raw: Data, data: MeetingMinutesData, groups: [String: Set<String>]) throws -> Data {
        guard let source = String(data: raw, encoding: .utf8),
              !source.contains("<!DOCTYPE"), !source.contains("<!ENTITY") else {
            throw MeetingTemplateError.malformedTemplate
        }
        let document: XMLDocument
        // ponytail: preserve the XML representation except formatting whitespace metadata.
        // That option hides whitespace-only w:t from stringValue; Word spaces are text, not layout.
        do {
            document = try XMLDocument(data: raw, options: XMLNode.Options.nodePreserveAll.subtracting(.nodePreserveWhitespace))
        }
        catch { throw MeetingTemplateError.malformedTemplate }
        guard let root = document.rootElement(), root.localName == "document", root.uri == wordNamespace,
              let body = root.elements(forLocalName: "body", uri: wordNamespace).first else {
            throw MeetingTemplateError.malformedTemplate
        }
        let pattern = try NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_]+)\s*\}\}"#)
        func tokens(_ node: XMLNode) -> [String] {
            let full = text(node) as NSString
            return pattern.matches(in: full as String, range: NSRange(location: 0, length: full.length)).map {
                full.substring(with: $0.range(at: 1))
            }
        }
        // Только фиксированные абзацы ОРИГИНАЛА. Та же фраза внутри реплики останется дословно.
        let children = (body.children ?? []).filter { node in
            !(node.localName == "p" && node.uri == wordNamespace && instructions.contains(text(node)))
        }
        var occurrences: [String: [Int]] = [:]
        for (index, child) in children.enumerated() {
            for token in tokens(child) { occurrences[token, default: []].append(index) }
        }
        let expected = groups.values.reduce(into: Set<String>()) { $0.formUnion($1) }
        guard Set(occurrences.keys) == expected, occurrences.values.allSatisfy({ $0.count == 1 }) else {
            throw MeetingTemplateError.malformedTemplate
        }
        var ranges: [(name: String, start: Int, end: Int)] = []
        for (name, edges) in MeetingTemplate.blockEdges {
            guard let start = occurrences[edges.0]?.first, let end = occurrences[edges.1]?.first, start <= end,
                  Set(children[start...end].flatMap(tokens)) == groups[name] else {
                throw MeetingTemplateError.malformedTemplate
            }
            ranges.append((name, start, end))
        }
        ranges.sort { $0.start < $1.start }
        for (previous, next) in zip(ranges, ranges.dropFirst()) where previous.end >= next.start {
            throw MeetingTemplateError.malformedTemplate
        }
        let starts = Dictionary(uniqueKeysWithValues: ranges.map { ($0.start, $0) })
        var filled: [XMLNode] = []
        var index = 0
        while index < children.count {
            if let block = starts[index] {
                let rows = data.blocks[block.name, default: []]
                if rows.isEmpty {
                    guard let paragraph = children[index].copy() as? XMLElement else {
                        throw MeetingTemplateError.malformedTemplate
                    }
                    let properties = paragraph.elements(forLocalName: "pPr", uri: wordNamespace).first?.copy() as? XMLNode
                    paragraph.setChildren(properties.map { [$0] } ?? [])
                    let run = XMLElement(name: "w:r", uri: wordNamespace)
                    let node = XMLElement(name: "w:t", uri: wordNamespace)
                    node.stringValue = "не зафиксировано в предоставленных данных"
                    run.addChild(node)
                    paragraph.addChild(run)
                    filled.append(paragraph)
                } else {
                    for row in rows {
                        for original in children[block.start...block.end] {
                            let clone = original.copy() as! XMLNode
                            try replaceTokens(clone, values: row, pattern: pattern)
                            filled.append(clone)
                        }
                    }
                }
                index = block.end + 1
            } else {
                let clone = children[index].copy() as! XMLNode
                try replaceTokens(clone, values: data.fields, pattern: pattern)
                filled.append(clone)
                index += 1
            }
        }
        body.setChildren(filled)
        document.characterEncoding = "UTF-8"
        return document.xmlData(options: [.nodePreserveAll])
    }

    /// Исходные UTF-16 смещения и замена справа налево сохраняют соседние runs и Unicode.
    static func replaceTokens(_ node: XMLNode, values: [String: String], pattern: NSRegularExpression) throws {
        let nodes = textNodes(node)
        var offsets: [NSRange] = []
        var full = ""
        for text in nodes {
            let value = text.stringValue ?? ""
            offsets.append(NSRange(location: (full as NSString).length, length: (value as NSString).length))
            full += value
        }
        let original = full as NSString
        for match in pattern.matches(in: full, range: NSRange(location: 0, length: original.length)).reversed() {
            guard let first = offsets.firstIndex(where: { NSLocationInRange(match.range.location, $0) }),
                  let last = offsets.firstIndex(where: { NSLocationInRange(NSMaxRange(match.range) - 1, $0) }),
                  let value = values[original.substring(with: match.range(at: 1))] else {
                throw MeetingTemplateError.malformedTemplate
            }
            let firstValue = (nodes[first].stringValue ?? "") as NSString
            let lastValue = (nodes[last].stringValue ?? "") as NSString
            let prefix = firstValue.substring(to: match.range.location - offsets[first].location)
            let suffix = lastValue.substring(from: NSMaxRange(match.range) - offsets[last].location)
            if first == last {
                nodes[first].stringValue = prefix + value + suffix
            } else {
                nodes[first].stringValue = prefix + value
                if first + 1 < last {
                    for index in (first + 1)..<last { nodes[index].stringValue = "" }
                }
                nodes[last].stringValue = suffix
            }
        }
        for text in nodes {
            let value = text.stringValue ?? ""
            guard !value.isEmpty, let parent = text.parent as? XMLElement else { continue }
            text.addAttribute(XMLNode.attribute(withName: "xml:space", uri: xmlNamespace, stringValue: "preserve") as! XMLNode)
            let parts = value.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
            text.stringValue = parts[0]
            var position = text.index
            for part in parts.dropFirst() {
                position += 1
                parent.insertChild(XMLElement(name: "w:br", uri: wordNamespace), at: position)
                position += 1
                let extra = XMLElement(name: "w:t", uri: wordNamespace)
                extra.addAttribute(XMLNode.attribute(withName: "xml:space", uri: xmlNamespace, stringValue: "preserve") as! XMLNode)
                extra.stringValue = part
                parent.insertChild(extra, at: position)
            }
        }
    }
}
