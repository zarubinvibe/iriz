// Лист значков: все фигуры набора одним кадром, в двух размерах.
//
// Значок нельзя утвердить по описанию. Он читается или не читается на
// шестнадцати пунктах, и увидеть это можно только глазами на настоящем
// рендере. Прибор снимает лист, дальше судит человек.
import AppKit
import SwiftUI

/// Снять лист значков в PNG. Возвращает путь.
@MainActor
public func irizWriteGlyphSheet(to url: URL) throws {
    let sizes: [CGFloat] = [16, 24, 44]
    let cell = CGSize(width: 150, height: 96)
    let cols = 4
    let rows = (IrizGlyph.allCases.count + cols - 1) / cols
    let full = CGSize(width: cell.width * CGFloat(cols), height: cell.height * CGFloat(rows))

    let sheet = VStack(spacing: 0) {
        ForEach(0..<rows, id: \.self) { row in
            HStack(spacing: 0) {
                ForEach(0..<cols, id: \.self) { column in
                    let index = row * cols + column
                    if index < IrizGlyph.allCases.count {
                        let glyph = IrizGlyph.allCases[index]
                        VStack(spacing: 8) {
                            HStack(spacing: 14) {
                                ForEach(sizes, id: \.self) { size in
                                    IrizGlyphView(glyph, size: size)
                                }
                            }
                            Text(glyph.rawValue)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: cell.width, height: cell.height)
                    } else {
                        Color.clear.frame(width: cell.width, height: cell.height)
                    }
                }
            }
        }
    }
    .frame(width: full.width, height: full.height)
    .background(Color.white)
    .foregroundStyle(Color.black)

    let view = NSHostingView(rootView: sheet)
    view.frame = CGRect(origin: .zero, size: full)
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        throw NSError(domain: "iriz.glyphs", code: 1)
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "iriz.glyphs", code: 2)
    }
    try data.write(to: url)
}
