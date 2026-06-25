import Foundation
import NaturalLanguage
import PDFKit
import UIKit
import Vision

/// Распознавание текста на сканах (PDF без текстового слоя) через Vision.
/// Возвращает предложения с боксами строк в координатах страницы — для подсветки.
enum OCRTextExtractor {

    private static let profile: any LanguageProfile = RussianProfile()

    /// Распознаёт документ. `progress(done, total)` вызывается на главном потоке.
    static func sentences(from document: PDFDocument,
                          pageRange: Range<Int>? = nil,
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
            let pageRect = page.bounds(for: .mediaBox)
            guard let observations = await recognize(page: page, pageRect: pageRect),
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

                let bb = obs.boundingBox   // нормализованный, origin внизу-слева
                let fullBox = CGRect(
                    x: bb.minX * pageRect.width,
                    y: bb.minY * pageRect.height,
                    width: bb.width * pageRect.width,
                    height: bb.height * pageRect.height
                )

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
                        let bb = obs.boundingBox
                        return CGRect(
                            x: bb.minX * pageRect.width,
                            y: bb.minY * pageRect.height,
                            width: bb.width * pageRect.width,
                            height: bb.height * pageRect.height
                        )
                    }()

                    boxes.append(subBox ?? info.fullBox)
                }

                // range остаётся nil — подсветка через аннотации по боксам.
                result.append(Sentence(
                    rawText: rawText,
                    pageIndex: pi,
                    range: nil,
                    boxes: boxes,
                    isHeading: heading
                ))
            }
        }

        return PDFTextExtractor.mergeCrossPage(result)
    }

    /// Распознавание одной страницы. Vision выполняется на фоновой очереди.
    private static func recognize(page: PDFPage, pageRect: CGRect) async -> [VNRecognizedTextObservation]? {
        let scale: CGFloat = 2
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        guard let cgImage = page.thumbnail(of: size, for: .mediaBox).cgImage else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = ["ru-RU", "en-US"]
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
}
