//
//  ZipArchiveReader.swift
//  Snapzy
//
//  Минимальный читатель ZIP без внешних утилит: stored и deflate, без ZIP64.
//

import Compression
import Foundation

enum ZipArchiveReader {
  enum ReadError: Error, Equatable {
    case notAnArchive
    case corruptedEntry(String)
    case unsupportedCompression(String, UInt16)
    case checksumMismatch(String)
  }

  /// Читает все entries архива в словарь «путь → данные». Каталоги пропускаются.
  static func entries(in archive: Data) throws -> [String: Data] {
    let bytes = [UInt8](archive)
    guard let endRecordOffset = endOfCentralDirectoryOffset(in: bytes) else {
      throw ReadError.notAnArchive
    }

    let entryCount = Int(bytes.uint16LE(at: endRecordOffset + 10))
    var cursor = Int(bytes.uint32LE(at: endRecordOffset + 16))
    var result: [String: Data] = [:]

    for _ in 0..<entryCount {
      guard cursor + 46 <= bytes.count, bytes.uint32LE(at: cursor) == 0x02014b50 else {
        throw ReadError.notAnArchive
      }
      let method = bytes.uint16LE(at: cursor + 10)
      let crc = bytes.uint32LE(at: cursor + 16)
      let compressedSize = Int(bytes.uint32LE(at: cursor + 20))
      let uncompressedSize = Int(bytes.uint32LE(at: cursor + 24))
      let nameLength = Int(bytes.uint16LE(at: cursor + 28))
      let extraLength = Int(bytes.uint16LE(at: cursor + 30))
      let commentLength = Int(bytes.uint16LE(at: cursor + 32))
      let localHeaderOffset = Int(bytes.uint32LE(at: cursor + 42))
      guard cursor + 46 + nameLength <= bytes.count else { throw ReadError.notAnArchive }
      let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
      cursor += 46 + nameLength + extraLength + commentLength

      if name.hasSuffix("/") { continue }

      // Размер имени и extra в локальном заголовке может отличаться от центрального каталога.
      guard localHeaderOffset + 30 <= bytes.count,
            bytes.uint32LE(at: localHeaderOffset) == 0x04034b50 else {
        throw ReadError.corruptedEntry(name)
      }
      let localNameLength = Int(bytes.uint16LE(at: localHeaderOffset + 26))
      let localExtraLength = Int(bytes.uint16LE(at: localHeaderOffset + 28))
      let dataStart = localHeaderOffset + 30 + localNameLength + localExtraLength
      guard dataStart + compressedSize <= bytes.count else { throw ReadError.corruptedEntry(name) }
      let payload = Data(bytes[dataStart..<(dataStart + compressedSize)])

      let data: Data
      switch method {
      case 0:
        data = payload
      case 8:
        guard let inflated = inflate(payload, expectedSize: uncompressedSize) else {
          throw ReadError.corruptedEntry(name)
        }
        data = inflated
      default:
        throw ReadError.unsupportedCompression(name, method)
      }

      guard data.count == uncompressedSize else { throw ReadError.corruptedEntry(name) }
      guard ZipCRC32.checksum(data) == crc else { throw ReadError.checksumMismatch(name) }
      result[name] = data
    }

    return result
  }

  /// Ищет End of Central Directory с конца: после него может идти комментарий до 64 КБ.
  private static func endOfCentralDirectoryOffset(in bytes: [UInt8]) -> Int? {
    guard bytes.count >= 22 else { return nil }
    let lowerBound = max(0, bytes.count - 22 - Int(UInt16.max))
    var offset = bytes.count - 22
    while offset >= lowerBound {
      if bytes.uint32LE(at: offset) == 0x06054b50 { return offset }
      offset -= 1
    }
    return nil
  }

  private static func inflate(_ data: Data, expectedSize: Int) -> Data? {
    guard expectedSize > 0 else { return Data() }
    var destination = [UInt8](repeating: 0, count: expectedSize)
    let decodedCount = data.withUnsafeBytes { sourceBuffer -> Int in
      guard let source = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
      // COMPRESSION_ZLIB в Compression — это raw deflate, как в ZIP.
      return compression_decode_buffer(
        &destination,
        destination.count,
        source,
        data.count,
        nil,
        COMPRESSION_ZLIB
      )
    }
    guard decodedCount == expectedSize else { return nil }
    return Data(destination)
  }
}

private extension Array where Element == UInt8 {
  func uint16LE(at offset: Int) -> UInt16 {
    guard offset + 2 <= count else { return 0 }
    return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
  }

  func uint32LE(at offset: Int) -> UInt32 {
    guard offset + 4 <= count else { return 0 }
    return UInt32(self[offset])
      | (UInt32(self[offset + 1]) << 8)
      | (UInt32(self[offset + 2]) << 16)
      | (UInt32(self[offset + 3]) << 24)
  }
}
