import IrizCore
// Зона переноса: бросил файл - он встал в очередь на расшифровку.
//
// Поведение снято с эталона (21st.dev, File Dropzone) и перенесено нативно:
// их код на React с Tailwind, у нас AppKit и SwiftUI, и вставить его физически
// некуда. Взято ровно то, что ценно: пунктирная рамка, которая на наведении
// файла подсвечивается, плитка со значком, строка про принимаемые типы, кнопка
// выбора рядом и список очереди со снятием строки крестиком.
//
// Значок свой, из набора продукта: чужие глифы SF узнаются как деталь macOS, а
// не как лицо продукта.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Один файл в очереди.
public struct IrizDropItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public let bytes: Int64

    public init(url: URL, bytes: Int64) {
        self.id = UUID()
        self.url = url
        self.bytes = bytes
    }
}

/// Человеческий размер файла. Один формат на весь продукт: рядом стоящие
/// «1,2 ГБ» и «1200 MB» читаются как две разные единицы.
public func irizDropSizeText(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    return formatter.string(fromByteCount: bytes)
}

/// Годится ли файл. Чистая функция: решение о приёме проверяется тестом без
/// окна и без диска.
public func irizDropAccepts(_ url: URL, extensions: [String]) -> Bool {
    extensions.contains(url.pathExtension.lowercased())
}

public struct IrizDropZone: View {
    public let title: String
    public let subtitle: String
    public let extensions: [String]
    public let onAdd: ([URL]) -> Void

    @State private var dragging = false
    @State private var refused: String?

    public init(title: String,
                subtitle: String,
                extensions: [String],
                onAdd: @escaping ([URL]) -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.extensions = extensions
        self.onAdd = onAdd
    }

    public var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 8) {
                IrizGlyphView(.files, size: 22)
                    .foregroundStyle(IRIZ_SUBTLE)
                    .frame(width: 44, height: 44)
                    .background {
                        Circle().strokeBorder(.primary.opacity(dragging ? 0.35 : 0.18),
                                              lineWidth: 1)
                    }

                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(IRIZ_SUBTLE)
                    .multilineTextAlignment(.center)

                Button("Выбрать файлы") { choose() }
                    .modifier(IrizDropZoneButton())
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.primary.opacity(dragging ? 0.06 : 0))
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.primary.opacity(dragging ? 0.45 : 0.2),
                                  style: StrokeStyle(lineWidth: dragging ? 1.6 : 1,
                                                     dash: dragging ? [] : [5, 4]))
            }
            // Рамка отвечает на файл над ней. Зона без отклика читается как
            // картинка, и человек не понимает, отпускать тут или нет.
            .animation(irizAnimation(.irizQuick), value: dragging)
            .onDrop(of: [.fileURL], isTargeted: $dragging) { providers in
                accept(providers)
                return true
            }

            if let refused {
                HStack(spacing: 6) {
                    IrizGlyphView(.files, size: 12)
                    Text(refused).font(.system(size: 11.5))
                }
                .foregroundStyle(.red)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        accept(panel.urls)
    }

    private func accept(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { accept([url]) }
            }
        }
    }

    private func accept(_ urls: [URL]) {
        let fitting = urls.filter { irizDropAccepts($0, extensions: extensions) }
        let refusedCount = urls.count - fitting.count
        // Отказ называется вслух и с числом. Молча проглоченный файл выглядит
        // как поломка переноса, и человек пробует снова тем же способом.
        refused = refusedCount == 0 ? nil : "Не приняты файлы: \(refusedCount). Годятся только \(extensions.joined(separator: ", "))."
        guard !fitting.isEmpty else { return }
        onAdd(fitting)
    }
}

/// Кнопка зоны: обведённая, не залитая. Залитая спорит с главной кнопкой
/// страницы, а выбор файла - не главное действие, а запасной путь к переносу.
struct IrizDropZoneButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

/// Строка очереди: имя, размер и крестик.
public struct IrizDropRow: View {
    public let item: IrizDropItem
    public let onRemove: () -> Void

    public init(item: IrizDropItem, onRemove: @escaping () -> Void) {
        self.item = item
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: 10) {
            IrizGlyphView(.files, size: 16)
                .foregroundStyle(IRIZ_SUBTLE)
                .frame(width: 34, height: 34)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.primary.opacity(0.14), lineWidth: 1)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.url.lastPathComponent)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(irizDropSizeText(item.bytes))
                    .font(.system(size: 11))
                    .foregroundStyle(IRIZ_SUBTLE)
            }
            Spacer()
            Button(action: onRemove) {
                IrizGlyphView(.files, size: 12).opacity(0)
                    .overlay(Text("✕").font(.system(size: 12)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(IRIZ_SUBTLE)
            .accessibilityLabel("Убрать \(item.url.lastPathComponent) из очереди")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.primary.opacity(0.04))
        }
    }
}
