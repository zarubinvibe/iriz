import Darwin
import Foundation
import os
import Testing

@testable import IrizDictate

@Suite("Шаблон и native DOCX встречи")
struct MeetingDOCXTests {
    private let word = MeetingDOCXExporter.wordNamespace

    private func temporary() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iriz-docx-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func run(_ path: String, _ arguments: [String]) throws -> Data {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        task.standardOutput = pipe
        try task.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        #expect(task.terminationStatus == 0)
        return output
    }

    private func part(_ name: String, archive: URL) throws -> Data {
        // unzip трактует даже отдельный аргумент как glob: [Content_Types].xml нужно экранировать.
        let literal = name.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "?", with: "\\?")
        return try run("/usr/bin/unzip", ["-p", archive.path, literal])
    }

    private func row(_ name: String, _ values: [String: String]) throws -> [String: String] {
        let keys = try #require(MeetingTemplate.groups(in: MeetingTemplate.directory())[name])
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, values[$0] ?? "не указано") })
    }

    private func paragraphs(_ xml: Data) throws -> [XMLElement] {
        let document = try XMLDocument(data: xml)
        let root = try #require(document.rootElement())
        let body = try #require(root.elements(forLocalName: "body", uri: word).first)
        return body.elements(forLocalName: "p", uri: word)
    }

    private func visibleText(_ node: XMLNode) -> String {
        if node.localName == "t", node.uri == word { return node.stringValue ?? "" }
        if node.localName == "br", node.uri == word { return "\n" }
        return (node.children ?? []).map(visibleText).joined()
    }

    private func saxText(_ raw: Data) throws -> MeetingDOCXSAXText {
        let reader = MeetingDOCXSAXText()
        let parser = XMLParser(data: raw)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        try #require(parser.parse())
        return reader
    }

    @Test("Переносимый bundle содержит согласованные 87 ключей; черновик заполнен полностью")
    func resourcesAndDefaults() throws {
        let directory = try MeetingTemplate.directory()
        for name in MeetingTemplate.hashes.keys { _ = try MeetingTemplate.verifiedFile(name, in: directory) }
        let data = try MeetingTemplate.emptyData()
        #expect(data.fields.count == 38)
        #expect(data.blocks.count == 7)
        #expect(data.blocks.values.allSatisfy { $0.isEmpty })
        #expect(data.fields["approval_status"] == "черновик")
        #expect(data.fields.filter { $0.key != "approval_status" }.values.allSatisfy { $0 == "не указано" })
        try MeetingTemplate.validate(data)
        #expect(try JSONDecoder().decode(MeetingMinutesData.self, from: JSONEncoder().encode(data)) == data)
    }

    @Test("Шаблон находится в перенесённом .app без абсолютного пути сборки")
    func portableAppResources() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Portable.app")
        let contents = app.appendingPathComponent("Contents")
        let resources = contents.appendingPathComponent("Resources/IrizApp_IrizDictate.bundle")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.iriz.portable-docx", "CFBundlePackageType": "APPL", "CFBundleExecutable": "iriz"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let copied = resources.appendingPathComponent("MeetingMinutes")
        try FileManager.default.copyItem(at: MeetingTemplate.directory(), to: copied)
        let bundle = try #require(Bundle(url: app))
        let found = try #require(MeetingTemplate.directory(in: bundle))
        #expect(found.standardizedFileURL == copied.standardizedFileURL)
        for name in MeetingTemplate.hashes.keys { _ = try MeetingTemplate.verifiedFile(name, in: found) }
    }

    @Test("JSON Schema требует все ключи на каждом уровне и запрещает посторонние")
    func schemaIsStrict() throws {
        let schema = try #require(JSONSerialization.jsonObject(with: MeetingTemplate.strictSchema()) as? [String: Any])
        var objectCount = 0
        func inspect(_ value: [String: Any]) throws {
            if let properties = value["properties"] as? [String: [String: Any]] {
                objectCount += 1
                #expect(Set(try #require(value["required"] as? [String])) == Set(properties.keys))
                #expect(value["additionalProperties"] as? Bool == false)
                for child in properties.values { try inspect(child) }
            }
            if let items = value["items"] as? [String: Any] { try inspect(items) }
        }
        try inspect(schema)
        #expect(objectCount == 10)
    }

    @Test("Пропуски, чужие ключи, пустые значения и запрещённые XML символы отклоняются")
    func rejectsIncompleteData() throws {
        let original = try MeetingTemplate.emptyData()
        var invalid: [MeetingMinutesData] = []
        var value = original; value.fields.removeValue(forKey: "meeting_id"); invalid.append(value)
        value = original; value.fields["invented"] = "private text"; invalid.append(value)
        value = original; value.blocks.removeValue(forKey: "topics"); invalid.append(value)
        value = original; value.blocks["invented"] = []; invalid.append(value)
        value = original; value.blocks["participants"] = [["participant_id": "P-001"]]; invalid.append(value)
        value = original; value.blocks["participants"] = [try row("participants", [:])]
        value.blocks["participants"]?[0]["invented"] = "private text"; invalid.append(value)
        for bad in ["", " \n\t", "private\u{0}text", "\u{0B}", "\u{FFFE}"] {
            value = original; value.fields["meeting_title"] = bad; invalid.append(value)
        }
        for data in invalid { #expect(throws: MeetingTemplateError.invalidData) { try MeetingTemplate.validate(data) } }
        let extraRoot = Data(#"{"fields":{},"blocks":{},"unexpected":"private text"}"#.utf8)
        #expect(throws: MeetingTemplateError.invalidData) { try JSONDecoder().decode(MeetingMinutesData.self, from: extraRoot) }
        #expect(!(MeetingTemplateError.invalidData.errorDescription ?? "").contains("private text"))
    }

    @Test("Ограничены одна строка, суммарный объём и число карточек")
    func bounds() throws {
        var data = try MeetingTemplate.emptyData()
        data.fields["meeting_title"] = String(repeating: "x", count: MeetingTemplate.maximumValueBytes + 1)
        #expect(throws: MeetingTemplateError.dataTooLarge) { try MeetingTemplate.validate(data) }
        data = try MeetingTemplate.emptyData()
        data.blocks["transcript_utterances"] = Array(repeating: try row("transcript_utterances", [
            "utterance_text": String(repeating: "x", count: MeetingTemplate.maximumValueBytes),
        ]), count: 17)
        #expect(throws: MeetingTemplateError.dataTooLarge) { try MeetingTemplate.validate(data) }
        data = try MeetingTemplate.emptyData()
        data.blocks["participants"] = Array(repeating: try row("participants", [:]), count: MeetingTemplate.maximumRows + 1)
        #expect(throws: MeetingTemplateError.dataTooLarge) { try MeetingTemplate.validate(data) }
    }

    @Test("DOCX сохраняет все остальные части, макет, две карточки, literal tokens и дословные строки")
    func archiveAndFormatting() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let templateDirectory = try MeetingTemplate.directory()
        let template = templateDirectory.appendingPathComponent("template.docx")
        let before = try Data(contentsOf: template)
        let output = directory.appendingPathComponent("meeting.docx")
        var data = try MeetingTemplate.emptyData()
        data.fields["meeting_title"] = "Обсуждение 🧪 <плана> & бюджета"
        data.blocks["participants"] = [
            try row("participants", ["participant_id": "P-001", "participant_name": "Анна"]),
            try row("participants", ["participant_id": "P-002", "participant_name": "Борис"]),
        ]
        let quotedInstruction = "Карточка участника — повторить для каждого приглашенного."
        let utterance = "Э-э, да, да… {{meeting_title}} <w:evil/> & 🧪\r\nВторая строка\rТретья\n\(quotedInstruction)"
        data.blocks["transcript_utterances"] = [
            try row("transcript_utterances", ["utterance_id": "U-001", "utterance_text": utterance]),
            try row("transcript_utterances", ["utterance_id": "U-002", "utterance_text": String(repeating: "Продолжение без сокращений. ", count: 800)]),
        ]
        try MeetingDOCXExporter.export(data, to: output)
        #expect(try Data(contentsOf: template) == before)
        let fileMode = try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? NSNumber
        #expect(fileMode?.intValue == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["meeting.docx"])
        let originalNames = String(decoding: try run("/usr/bin/unzip", ["-Z1", template.path]), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }
        let outputNames = String(decoding: try run("/usr/bin/unzip", ["-Z1", output.path]), as: UTF8.self)
            .split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }
        #expect(Set(originalNames) == Set(outputNames))
        for name in originalNames where name != "word/document.xml" {
            #expect(try part(name, archive: template) == part(name, archive: output))
        }
        let originalXML = try part("word/document.xml", archive: template)
        let exportedXML = try part("word/document.xml", archive: output)
        let originalDocument = try XMLDocument(data: originalXML)
        let exportedDocument = try XMLDocument(data: exportedXML)
        #expect(originalDocument.rootElement()?.namespaces?.map(\.xmlString).sorted() == exportedDocument.rootElement()?.namespaces?.map(\.xmlString).sorted())
        let originalSection = try originalDocument.nodes(forXPath: "//*[local-name()='sectPr']").first?.xmlString
        let exportedSection = try exportedDocument.nodes(forXPath: "//*[local-name()='sectPr']").first?.xmlString
        #expect(originalSection == exportedSection)
        let items = try paragraphs(exportedXML)
        let texts = items.map(visibleText)
        #expect(texts.first == "ЧАСТЬ I. ПРОТОКОЛ ВСТРЕЧИ")
        #expect(!texts.contains("ПРОТОКОЛ И ПОЛНАЯ РАСШИФРОВКА ВСТРЕЧИ"))
        #expect(texts.contains("Идентификатор участника: P-001"))
        #expect(texts.contains("Идентификатор участника: P-002"))
        #expect(texts.contains(utterance.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")))
        #expect(texts.contains(String(repeating: "Продолжение без сокращений. ", count: 800)))
        #expect(!texts.contains(quotedInstruction))
        #expect(try exportedDocument.nodes(forXPath: "//*[local-name()='evil']").isEmpty)
        let secondPart = try #require(items.first { visibleText($0) == "ЧАСТЬ II. ПОЛНАЯ РАСШИФРОВКА ВСТРЕЧИ" })
        #expect(try secondPart.nodes(forXPath: ".//*[local-name()='pageBreakBefore']").count == 1)
        #expect(texts.filter { $0 == "не зафиксировано в предоставленных данных" }.count == 5)
    }

    @Test("Независимый SAX-reader сохраняет отдельные пробельные w:t без stringValue")
    func saxReaderRetainsWhitespaceOnlyRuns() throws {
        let raw = Data(#"<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:r><w:t>Файл</w:t></w:r><w:r><w:t xml:space="preserve"> </w:t></w:r><w:r><w:t>записи</w:t></w:r><w:r><w:t xml:space="preserve">  </w:t></w:r><w:r><w:t>готов</w:t></w:r></w:p>"#.utf8)
        let text = try saxText(raw)
        #expect(text.paragraphs == ["Файл записи  готов"])
        #expect(text.textRuns == ["Файл", " ", "записи", "  ", "готов"])
    }

    @Test("Базовый DOCX с одной репликой сохраняет четыре пробельных run и полные подписи")
    func baseDataExportPreservesWhitespaceOnlyRuns() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let template = try MeetingTemplate.directory().appendingPathComponent("template.docx")
        let source = try saxText(part("word/document.xml", archive: template))
        #expect(source.paragraphs.contains("Файл записи: {{utterance_recording_file}}"))
        #expect(source.paragraphs.contains("Таймкод от начала файла — ЧЧ:ММ:СС–ЧЧ:ММ:СС: {{utterance_start}}–{{utterance_end}}"))
        #expect(source.textRuns.filter { !$0.isEmpty && $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count == 6)

        var data = try MeetingTemplate.emptyData()
        let raw = "Синтетическая реплика: э-э, да, да…  Без сокращений."
        data.blocks["transcript_utterances"] = [try row("transcript_utterances", [
            "utterance_id": "U-001",
            "utterance_recording_file": "synthetic-recording.wav",
            "utterance_start": "таймкод не указан",
            "utterance_end": "таймкод не указан",
            "utterance_text": raw,
        ])]
        #expect(data.blocks.filter { $0.key != "transcript_utterances" }.values.allSatisfy { $0.isEmpty })
        let output = directory.appendingPathComponent("base-data.docx")
        try MeetingDOCXExporter.export(data, to: output)
        let actual = try saxText(part("word/document.xml", archive: output))

        #expect(actual.paragraphs.contains("Файл записи: synthetic-recording.wav"))
        #expect(actual.paragraphs.contains("Таймкод от начала файла — ЧЧ:ММ:СС–ЧЧ:ММ:СС: таймкод не указан–таймкод не указан"))
        #expect(actual.paragraphs.contains(raw))
        #expect(!actual.paragraphs.contains { $0.contains("Файлзаписи") || $0.contains("Таймкодотначалафайла") })
        #expect(actual.paragraphs.filter { $0 == "не зафиксировано в предоставленных данных" }.count == 6)
        // Два пробельных run принадлежали удалённой пустой карточке участника; остальные четыре остаются.
        #expect(actual.textRuns.filter { !$0.isEmpty && $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } == [" ", " ", " ", " "])
    }

    @Test("Split-run подстановка сохраняет жирное окружение и не сканирует вставленные токены")
    func splitRuns() throws {
        let source = #"<w:p xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:r><w:rPr><w:b/></w:rPr><w:t>До 🧪 {{mee</w:t></w:r><w:r><w:t>ting_id}} между {{meeting_title}} после</w:t></w:r></w:p>"#
        let paragraph = try XMLElement(xmlString: source)
        let pattern = try NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_]+)\s*\}\}"#)
        try MeetingDOCXExporter.replaceTokens(paragraph, values: ["meeting_id": "{{meeting_title}}", "meeting_title": "значение"], pattern: pattern)
        #expect(visibleText(paragraph) == "До 🧪 {{meeting_title}} между значение после")
        #expect(try paragraph.nodes(forXPath: ".//*[local-name()='b']").count == 1)
        #expect(MeetingDOCXExporter.textNodes(paragraph).first?.stringValue == "До 🧪 {{meeting_title}}")
    }

    @Test("Дословная реплика, полностью совпавшая с инструкцией, остаётся; изменённые поля XML отклоняются")
    func literalInstructionAndChangedXML() throws {
        let resources = try MeetingTemplate.directory()
        let groups = try MeetingTemplate.groups(in: resources)
        let raw = try part("word/document.xml", archive: resources.appendingPathComponent("template.docx"))
        let instruction = "Карточка участника — повторить для каждого приглашенного."
        var data = try MeetingTemplate.emptyData()
        data.blocks["transcript_utterances"] = [try row("transcript_utterances", ["utterance_text": instruction])]
        let filled = try MeetingDOCXExporter.fillDocument(raw, data: data, groups: groups)
        let texts = try paragraphs(filled).map(visibleText)
        #expect(texts.filter { $0 == instruction }.count == 1)
        #expect(texts.filter { MeetingDOCXExporter.instructions.contains($0) }.count == 1)
        let source = String(decoding: raw, as: UTF8.self)
        #expect(source.contains("meeting_id"))
        let altered = Data(source.replacingOccurrences(of: "meeting_id", with: "unexpected_field").utf8)
        #expect(throws: MeetingTemplateError.malformedTemplate) {
            try MeetingDOCXExporter.fillDocument(altered, data: data, groups: groups)
        }
        let entity = Data("<!DOCTYPE document [<!ENTITY external SYSTEM 'file:///private/secret'>]><document/>".utf8)
        #expect(throws: MeetingTemplateError.malformedTemplate) {
            try MeetingDOCXExporter.fillDocument(entity, data: data, groups: groups)
        }
    }

    @Test("Результат совпадает по тексту с эталонным Python-примером после удаления инструкций")
    func pythonReference() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = try MeetingTemplate.directory()
        let fixture = try JSONDecoder().decode(MeetingMinutesData.self, from: Data(contentsOf: resources.appendingPathComponent("examples/data.example.json")))
        var data = try MeetingTemplate.emptyData()
        data.fields.merge(fixture.fields) { _, right in right }
        for (name, rows) in fixture.blocks { data.blocks[name] = try rows.map { try row(name, $0) } }
        let output = directory.appendingPathComponent("synthetic.docx")
        try MeetingDOCXExporter.export(data, to: output)
        let expected = try saxText(part("word/document.xml", archive: resources.appendingPathComponent("examples/filled.example.docx")))
            .paragraphs.filter { !MeetingDOCXExporter.instructions.contains($0) }
        let actual = try saxText(part("word/document.xml", archive: output)).paragraphs
        #expect(actual == expected)
    }

    @Test("Существующий файл, сам шаблон и dangling symlink не перезаписываются")
    func noOverwrite() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = try MeetingTemplate.emptyData()
        let existing = directory.appendingPathComponent("existing.docx")
        let sentinel = Data("original".utf8)
        try sentinel.write(to: existing)
        #expect(throws: MeetingTemplateError.outputExists) { try MeetingDOCXExporter.export(data, to: existing) }
        #expect(try Data(contentsOf: existing) == sentinel)
        let link = directory.appendingPathComponent("link.docx")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory.appendingPathComponent("absent.docx"))
        #expect(throws: MeetingTemplateError.outputExists) { try MeetingDOCXExporter.export(data, to: link) }
        let template = try MeetingTemplate.directory().appendingPathComponent("template.docx")
        let original = try Data(contentsOf: template)
        #expect(throws: MeetingTemplateError.outputExists) { try MeetingDOCXExporter.export(data, to: template) }
        #expect(try Data(contentsOf: template) == original)
    }

    @Test("Изменённый архив и symlink входа отклоняются до запуска ditto")
    func immutableTemplateBoundary() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = try MeetingTemplate.directory()
        let package = directory.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        for name in ["fields.json", "data.schema.json"] {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: package.appendingPathComponent(name))
        }
        let template = package.appendingPathComponent("template.docx")
        let data = try MeetingTemplate.emptyData()
        let output = directory.appendingPathComponent("result.docx")
        try Data("not a zip".utf8).write(to: template)
        #expect(throws: MeetingTemplateError.alteredTemplate) { try MeetingDOCXExporter.export(data, to: output, templateDirectory: package) }
        try FileManager.default.removeItem(at: template)
        try FileManager.default.createSymbolicLink(at: template, withDestinationURL: resources.appendingPathComponent("template.docx"))
        #expect(throws: MeetingTemplateError.alteredTemplate) { try MeetingDOCXExporter.export(data, to: output, templateDirectory: package) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("FIFO вместо файла отклоняется без ожидания писателя")
    func fifoInputFailsPromptly() throws {
        let directory = try temporary()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["fields.json", "template.docx"] {
            let fifo = directory.appendingPathComponent(name)
            try #require(mkfifo(fifo.path, 0o600) == 0)
            let started = DispatchSemaphore(value: 0)
            let finished = DispatchSemaphore(value: 0)
            let rejected = OSAllocatedUnfairLock(initialState: false)
            DispatchQueue.global(qos: .userInitiated).async {
                started.signal()
                do { _ = try MeetingTemplate.verifiedFile(name, in: directory) }
                catch { rejected.withLock { $0 = (error as? MeetingTemplateError) == .alteredTemplate } }
                finished.signal()
            }
            #expect(started.wait(timeout: .now() + 1) == .success)
            let promptly = finished.wait(timeout: .now() + 1)
            if promptly == .timedOut {
                // При возврате дефекта тест FAIL, но writer освобождает зависший open(O_RDONLY).
                let writer = open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
                if writer >= 0 { close(writer) }
                #expect(finished.wait(timeout: .now() + 1) == .success)
            }
            #expect(promptly == .success)
            #expect(rejected.withLock { $0 })
        }
    }
}

/// XMLParser читает реальные character events. XMLNode.stringValue теряет
/// whitespace-only w:t даже тогда, когда xmlString ещё содержит пробел.
private final class MeetingDOCXSAXText: NSObject, XMLParserDelegate {
    private(set) var paragraphs: [String] = []
    private(set) var textRuns: [String] = []
    private var paragraph: String?
    private var text: String?
    private let word = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard namespaceURI == word else { return }
        switch elementName {
        case "p": paragraph = ""
        case "t": text = ""
        case "br": paragraph? += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }
    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { append(whitespaceString) }

    private func append(_ value: String) {
        guard text != nil else { return }
        text? += value
        paragraph? += value
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard namespaceURI == word else { return }
        switch elementName {
        case "t":
            if let text { textRuns.append(text) }
            text = nil
        case "p":
            if let paragraph { paragraphs.append(paragraph) }
            paragraph = nil
        default: break
        }
    }
}
