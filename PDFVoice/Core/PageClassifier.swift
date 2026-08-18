import CoreGraphics
import PDFKit
import UIKit

enum PageKind { case text, ocr }

/// Дешёвая классификация: только плотность букв из текстового слоя, без рендера.
/// Возвращает .text или .ocr.
/// Вызывать можно на main thread; page.string не рендерит thumbnail. На больших
/// книгах (сотни страниц) сама классификация всё равно дорога суммарно — это
/// повод звать её вне main thread (см. `ReaderViewModel.load`), а не повод
/// оставлять этот проход посимвольным по всей странице.
func textDensityKind(_ page: PDFPage) -> PageKind {
    textDensityKind(ofText: page.string ?? "")
}

/// Логика плотности букв, вынесенная в String-версию — без зависимости от
/// PDFPage, чтобы её можно было проверить в изолированном harness'е.
///
/// Считаем по ПРЕФИКСУ текста (до ~400 значимых символов), не по всей странице:
/// порог 40 non-space символов уже даёт статистически устойчивое решение
/// text/ocr, а полный посимвольный проход по плотной странице (Character-
/// итерация + unicode-свойства на каждый символ) на большой книге суммарно
/// заметно дороже, чем нужно для этого решения. `unicodeScalars` вместо
/// `Character` — дешевле (без построения grapheme-кластеров).
func textDensityKind(ofText s: String) -> PageKind {
    var letters = 0, nonSpace = 0
    let sampleLimit = 400
    for scalar in s.unicodeScalars {
        guard !scalar.properties.isWhitespace else { continue }
        nonSpace += 1
        if scalar.properties.isAlphabetic { letters += 1 }
        if nonSpace >= sampleLimit { break }
    }
    if nonSpace >= 40 {
        let ratio = Double(letters) / Double(nonSpace)
        if ratio >= 0.35 { return .text }
    }
    return .ocr
}

/// Рендерит страницу в маленький (48×48) thumbnail и проверяет разброс яркости.
/// Если (max_luma − min_luma) < 24 — страница практически однотонная (пустая).
/// При невозможности получить пиксели возвращает false (лучше лишний OCR, чем пропуск).
/// Дорогая операция — вызывать только off main thread.
func isBlankPage(_ page: PDFPage) -> Bool {
    let thumb = page.thumbnail(of: CGSize(width: 48, height: 48), for: .mediaBox)
    guard let cgImage = thumb.cgImage else { return false }

    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return false }

    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

    guard let context = CGContext(
        data: &pixelData,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return false }

    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    var minLuma: Int = 255
    var maxLuma: Int = 0

    let pixelCount = width * height
    var offset = 0
    for _ in 0..<pixelCount {
        let r = Int(pixelData[offset])
        let g = Int(pixelData[offset + 1])
        let b = Int(pixelData[offset + 2])
        // BT.601 integer approximation: (77*R + 150*G + 29*B) >> 8
        let luma = (77 * r + 150 * g + 29 * b) >> 8
        if luma < minLuma { minLuma = luma }
        if luma > maxLuma { maxLuma = luma }
        offset += bytesPerPixel
    }

    return (maxLuma - minLuma) < 24
}
