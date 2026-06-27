import Compression
import Foundation

/// Минимальный read-only ZIP-ридер (без сторонних зависимостей). Нужен для EPUB и
/// DOCX — оба суть zip-контейнеры. Поддерживает метод 0 (stored) и 8 (deflate);
/// deflate разжимается системным `Compression` (`COMPRESSION_ZLIB` = raw DEFLATE,
/// RFC 1951 — ровно то, что хранит zip). Zip64 не поддерживается (книги < 4 ГБ).
struct ZipArchive {
    private let data: Data
    private struct Entry {
        let method: UInt16
        let compSize: Int
        let uncompSize: Int
        let localHeaderOffset: Int
    }
    private var entries: [String: Entry] = [:]
    private(set) var names: [String] = []

    init?(data: Data) {
        self.data = data
        guard let eocd = ZipArchive.findEOCD(data) else { return nil }
        let cdOffset = Int(data.le32(eocd + 16))
        let count = Int(data.le16(eocd + 10))
        var p = cdOffset
        for _ in 0..<count {
            guard p + 46 <= data.count, data.le32(p) == 0x0201_4b50 else { break }
            let method = data.le16(p + 10)
            let compSize = Int(data.le32(p + 20))
            let uncompSize = Int(data.le32(p + 24))
            let fnLen = Int(data.le16(p + 28))
            let extraLen = Int(data.le16(p + 30))
            let commentLen = Int(data.le16(p + 32))
            let localOffset = Int(data.le32(p + 42))
            let nameStart = p + 46
            guard nameStart + fnLen <= data.count else { break }
            let name = String(decoding: data[nameStart..<nameStart + fnLen], as: UTF8.self)
            entries[name] = Entry(method: method, compSize: compSize,
                                  uncompSize: uncompSize, localHeaderOffset: localOffset)
            names.append(name)
            p = nameStart + fnLen + extraLen + commentLen
        }
    }

    /// Возвращает разжатое содержимое записи по имени (или nil).
    func data(for name: String) -> Data? {
        guard let e = entries[name] else { return nil }
        let lo = e.localHeaderOffset
        guard lo + 30 <= data.count, data.le32(lo) == 0x0403_4b50 else { return nil }
        let fnLen = Int(data.le16(lo + 26))
        let extraLen = Int(data.le16(lo + 28))
        let start = lo + 30 + fnLen + extraLen
        guard start + e.compSize <= data.count else { return nil }
        let comp = data.subdata(in: start..<start + e.compSize)
        switch e.method {
        case 0:  return comp                                   // stored
        case 8:  return ZipArchive.inflate(comp, expectedSize: e.uncompSize)
        default: return nil
        }
    }

    /// Сканирует End-Of-Central-Directory с конца (учитывая возможный комментарий).
    private static func findEOCD(_ data: Data) -> Int? {
        let n = data.count
        guard n >= 22 else { return nil }
        let minP = max(0, n - 22 - 0xFFFF)
        var p = n - 22
        while p >= minP {
            if data.le32(p) == 0x0605_4b50 { return p }
            p -= 1
        }
        return nil
    }

    private static func inflate(_ comp: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var dst = Data(count: expectedSize)
        let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
            comp.withUnsafeBytes { srcPtr -> Int in
                guard let d = dstPtr.bindMemory(to: UInt8.self).baseAddress,
                      let s = srcPtr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expectedSize, s, comp.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return written == expectedSize ? dst : Data(dst.prefix(written))
    }
}

private extension Data {
    func le16(_ o: Int) -> UInt16 { UInt16(self[o]) | (UInt16(self[o + 1]) << 8) }
    func le32(_ o: Int) -> UInt32 {
        UInt32(self[o]) | (UInt32(self[o + 1]) << 8) | (UInt32(self[o + 2]) << 16) | (UInt32(self[o + 3]) << 24)
    }
}
