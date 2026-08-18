import Foundation
import NaturalLanguage
import PDFKit
import UIKit
import Vision

/// Распознавание текста на сканах (PDF без текстового слоя) через Vision.
/// Возвращает предложения с боксами строк в координатах страницы — для подсветки.
enum OCRTextExtractor {

    /// Распознаёт документ. `progress(done, total)` вызывается на главном потоке.
    /// `profile` — языковой профиль книги (по умолчанию русский, как раньше).
    static func sentences(from document: PDFDocument,
                          pageRange: Range<Int>? = nil,
                          profile: any LanguageProfile = LanguageProfiles.default,
                          progress: @escaping (Int, Int) -> Void) async -> [Sentence] {
        let pageCount = document.pageCount
        guard pageCount > 0 else { return [] }

        let range = pageRange ?? (0..<pageCount)
        guard !range.isEmpty else { return [] }

        // MARK: — Шаг 1: OCR всех страниц диапазона → параллельные массивы строк и боксов.

        // pageObservations[i] соответствует странице range.lowerBound + i.
        // Элемент nil — страница недоступна или OCR вернул пустой результат.
        // candidate хранится для под-строчного boundingBox(for:) при сборке боксов предложения.
        var pageObservations: [[(line: TextPipeline.PageLine,
                                 candidate: VNRecognizedText,
                                 fullBox: CGRect,
                                 utf16Len: Int)]?] =
            Array(repeating: nil, count: range.count)

        for (idx, pi) in range.enumerated() {
            let done = idx + 1
            let total = range.count
            defer { Task { @MainActor in progress(done, total) } }

            guard let page = document.page(at: pi) else { continue }

            // Пустые страницы-разделители не несут текста — полный Vision-проход
            // (0.5–1.5 с) на них потрачен впустую. `processMixedPages` уже
            // фильтрует их перед вызовом `sentences` для своих одиночных OCR-
            // страниц (проверка тут для них избыточна, но безвредна); для
            // batched-вызовов из `runOCR` (весь чисто-OCR путь) это единственная
            // точка проверки. Индекс страницы всё равно остаётся в диапазоне —
            // `loadedPageCount` продвигается по границе батча, как и раньше,
            // просто для этой страницы не будет ни OCR, ни предложений.
            let blank = await Task.detached(priority: .background) { isBlankPage(page) }.value
            guard !blank else { continue }

            let pageRect = page.bounds(for: .mediaBox)
            guard let observations = await recognize(page: page, pageRect: pageRect,
                                                     languages: recognitionLanguages(for: profile.code)),
                  !observations.isEmpty else { continue }

            // Строим параллельные массивы для этой страницы.
            // startUTF16 накапливается по мере добавления строк; разделитель = 1 код-юнит (пробел).
            var entries: [(line: TextPipeline.PageLine,
                           candidate: VNRecognizedText,
                           fullBox: CGRect,
                           utf16Len: Int)] = []
            var cumulativeUTF16 = 0

            for obs in observations {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let str = candidate.string
                let utf16Len = str.utf16.count
                let pageLine = TextPipeline.PageLine(text: str, startUTF16: cumulativeUTF16)

                let bb = obs.boundingBox   // нормализованный, origin внизу-слева, координаты ОТОБРАЖАЕМОЙ страницы
                let fullBox = mapVisionBox(bb, pageRect: pageRect, rotation: page.rotation)

                entries.append((line: pageLine, candidate: candidate, fullBox: fullBox, utf16Len: utf16Len))
                // +1 за разделитель-пробел между строками
                cumulativeUTF16 += utf16Len + 1
            }

            pageObservations[idx] = entries.isEmpty ? nil : entries
        }

        // MARK: — Шаг 2: Детект колонтитулов по всем страницам диапазона (паритет с текстовым путём).

        var allPageLines: [[TextPipeline.PageLine]] = []
        allPageLines.reserveCapacity(range.count)
        for entries in pageObservations {
            allPageLines.append(entries?.map { $0.line } ?? [])
        }
        let boilerplate = TextPipeline.detectBoilerplateWindowed(pages: allPageLines)

        // MARK: — Шаг 3: Очистка + токенизация + маппинг боксов по origIndex.

        var result: [Sentence] = []

        for (idx, pi) in range.enumerated() {
            guard let entries = pageObservations[idx], !entries.isEmpty else { continue }
            guard let page = document.page(at: pi) else { continue }
            let pageRect = page.bounds(for: .mediaBox)

            let lines = entries.map { $0.line }

            // Диапазоны UTF-16 каждой строки в синтетической строке страницы
            // (нужны для сопоставления с origIndex после cleanPage).
            // lineInfos[i]: полуоткрытый интервал [start, end), кандидат Vision и полный бокс.
            struct LineInfo {
                let start: Int
                let end: Int
                let candidate: VNRecognizedText
                let fullBox: CGRect
            }
            var lineInfos: [LineInfo] = []
            lineInfos.reserveCapacity(entries.count)
            for entry in entries {
                lineInfos.append(LineInfo(
                    start: entry.line.startUTF16,
                    end: entry.line.startUTF16 + entry.utf16Len,
                    candidate: entry.candidate,
                    fullBox: entry.fullBox
                ))
            }

            let dropped = TextPipeline.droppedIndices(lines: lines, boilerplate: boilerplate)
            let (cleaned, origIndex) = TextPipeline.cleanPage(lines, dropped: dropped)
            guard !cleaned.isEmpty else { continue }

            let cleanedUnits = Array(cleaned.utf16)

            for range in profile.sentenceRanges(in: cleaned) {
                let ns = NSRange(range, in: cleaned)
                guard ns.length > 0 else { continue }

                // Обрезаем пробелы по краям (в координатах чистого текста).
                var lo = ns.location
                var hi = ns.location + ns.length - 1
                while lo <= hi, cleanedUnits[lo] == 0x20 { lo += 1 }
                while hi >= lo, cleanedUnits[hi] == 0x20 { hi -= 1 }
                guard lo <= hi else { continue }

                let rawText = String(utf16CodeUnits: Array(cleanedUnits[lo...hi]), count: hi - lo + 1)
                guard !rawText.isEmpty else { continue }

                let heading = profile.isHeading(rawText)

                // Исходный UTF-16-диапазон предложения через origIndex.
                let oLo = origIndex[lo]
                let oHi = origIndex[hi]   // последний символ включительно

                // Собираем под-строчные боксы для каждой строки, пересекающейся с [oLo, oHi].
                var boxes: [CGRect] = []
                for info in lineInfos {
                    guard info.start <= oHi && info.end > oLo else { continue }

                    // Пересечение в UTF-16 синтетической страницы.
                    let interLo = max(info.start, oLo)
                    let interHi = min(info.end, oHi + 1)   // полуоткрытый конец

                    // Если предложение покрывает строку целиком — используем fullBox напрямую.
                    if interLo == info.start && interHi == info.end {
                        boxes.append(info.fullBox)
                        continue
                    }

                    // Смещения внутри строки (UTF-16).
                    let localLo = interLo - info.start
                    let localHi = interHi - info.start   // исключительно

                    // Переводим в Range<String.Index> внутри candidate.string через UTF-16-вид.
                    let str = info.candidate.string
                    let utf16View = str.utf16
                    let subBox: CGRect? = {
                        guard localLo < localHi,
                              localLo >= 0,
                              localHi <= utf16View.count else { return nil }
                        let startIdx = utf16View.index(utf16View.startIndex,
                                                       offsetBy: localLo)
                        let endIdx   = utf16View.index(utf16View.startIndex,
                                                       offsetBy: localHi)
                        // boundingBox(for:) требует Range<String.Index>
                        guard let strStart = startIdx.samePosition(in: str),
                              let strEnd   = endIdx.samePosition(in: str),
                              strStart < strEnd else { return nil }
                        guard let obs = try? info.candidate.boundingBox(for: strStart..<strEnd) else {
                            return nil
                        }
                        return mapVisionBox(obs.boundingBox, pageRect: pageRect, rotation: page.rotation)
                    }()

                    boxes.append(subBox ?? info.fullBox)
                }

                // range остаётся nil — подсветка через аннотации по боксам.
                result.append(Sentence(
                    rawText: rawText,
                    pageIndex: pi,
                    range: nil,
                    boxes: boxes,
                    isHeading: heading,
                    language: profile.code
                ))
            }
        }

        return PDFTextExtractor.mergeCrossPage(result)
    }

    /// Языки распознавания в порядке приоритета для языка книги. Порядок влияет
    /// на точность Vision: первый язык считается основным. Второй оставляем
    /// всегда — в книгах бывают вкрапления, и терять их из-за порядка не нужно.
    private static func recognitionLanguages(for code: String) -> [String] {
        code.lowercased().hasPrefix("en") ? ["en-US", "ru-RU"] : ["ru-RU", "en-US"]
    }

    /// Распознавание одной страницы. Vision выполняется на фоновой очереди.
    private static func recognize(page: PDFPage, pageRect: CGRect,
                                  languages: [String]) async -> [VNRecognizedTextObservation]? {
        let scale: CGFloat = 2
        // `thumbnail(of:for:)` рендерит страницу КАК ОНА ОТОБРАЖАЕТСЯ — с учётом
        // `/Rotate`. Запрашивать размер в неповёрнутых mediaBox-пропорциях для
        // повёрнутой на 90/270 страницы значит растянуть/сжать кадр под чужой
        // аспект — на этом искажении и OCR, и координаты Vision поехали бы.
        let display = displaySize(for: pageRect, rotation: page.rotation)
        let size = CGSize(width: display.width * scale, height: display.height * scale)
        guard let cgImage = page.thumbnail(of: size, for: .mediaBox).cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = languages
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
                do {
                    try handler.perform([request])
                    continuation.resume(returning: request.results as? [VNRecognizedTextObservation])
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Геометрия: поворот страницы и origin mediaBox

    /// Нормализует `/Rotate` (может прийти отрицательным или ≥360) к {0, 90, 180, 270}.
    private static func normalizedRotation(_ rotation: Int) -> Int {
        ((rotation % 360) + 360) % 360
    }

    /// Размер страницы КАК ОНА ОТОБРАЖАЕТСЯ: при повороте на 90/270 стороны mediaBox
    /// меняются местами (портрет становится альбомом и наоборот).
    private static func displaySize(for pageRect: CGRect, rotation: Int) -> CGSize {
        normalizedRotation(rotation) == 90 || normalizedRotation(rotation) == 270
            ? CGSize(width: pageRect.height, height: pageRect.width)
            : CGSize(width: pageRect.width, height: pageRect.height)
    }

    /// Точка в координатах ОТОБРАЖАЕМОЙ (уже повёрнутой) страницы → точка в
    /// координатах НЕповёрнутого mediaBox (origin снизу-слева, `unrotatedSize`
    /// — исходные width/height страницы). `/Rotate` в PDF — поворот ПО ЧАСОВОЙ
    /// стрелке при отображении; здесь применяем обратное преобразование.
    /// Для 90/180/270 формулы выведены из стандартного поворота вектора по
    /// часовой стрелке (x,y)→(y,−x) с переносом в неотрицательный квадрант,
    /// инвертированы аналитически и проверены харнессом (точка/прямоугольник
    /// туда-обратно).
    private static func unrotatedPoint(_ p: CGPoint, rotation: Int, unrotatedSize: CGSize) -> CGPoint {
        let w = unrotatedSize.width
        let h = unrotatedSize.height
        switch normalizedRotation(rotation) {
        case 90:  return CGPoint(x: w - p.y, y: p.x)
        case 180: return CGPoint(x: w - p.x, y: h - p.y)
        case 270: return CGPoint(x: p.y, y: h - p.x)
        default:  return p
        }
    }

    /// Прямоугольник в координатах отображаемой страницы → в координатах
    /// неповёрнутого mediaBox. Поворот на кратные 90° сохраняет прямоугольник
    /// осеосным, но какая пара углов становится min/max — зависит от угла,
    /// поэтому переводим все 4 угла и берём bounding box результата, а не
    /// только min/max точки.
    private static func unrotatedRect(_ r: CGRect, rotation: Int, unrotatedSize: CGSize) -> CGRect {
        let corners = [
            CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
            CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY),
        ].map { unrotatedPoint($0, rotation: rotation, unrotatedSize: unrotatedSize) }
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Нормализованный (0…1, origin снизу-слева) бокс Vision — в координатах
    /// ОТОБРАЖАЕМОЙ страницы — в абсолютные координаты страницы (mediaBox,
    /// неповёрнутое пространство + `pageRect.origin`, который PDF с ненулевым
    /// origin mediaBox не забывает прибавить). `PDFAnnotation.bounds` ожидает
    /// координаты именно в этом пространстве — PDFKit сам поворачивает
    /// отрисовку аннотации согласно `/Rotate` страницы.
    private static func mapVisionBox(_ normalized: CGRect, pageRect: CGRect, rotation: Int) -> CGRect {
        let display = displaySize(for: pageRect, rotation: rotation)
        let displayRect = CGRect(
            x: normalized.minX * display.width,
            y: normalized.minY * display.height,
            width: normalized.width * display.width,
            height: normalized.height * display.height
        )
        let unrotated = unrotatedRect(displayRect, rotation: rotation,
                                      unrotatedSize: CGSize(width: pageRect.width, height: pageRect.height))
        return unrotated.offsetBy(dx: pageRect.minX, dy: pageRect.minY)
    }
}
