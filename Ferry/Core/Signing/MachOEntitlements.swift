import Foundation

/// Reads the entitlements a Mach-O binary was signed with, from the entitlements blob in its
/// code signature (the same data `codesign -d --entitlements` shows). Thin or fat binaries;
/// for fat ones the first 64-bit slice is used. Returns nil if there's no readable blob.
enum MachOEntitlements {
    static func read(_ data: Data) -> [String: Any]? {
        let bytes = [UInt8](data)
        guard let slice = firstSlice(bytes) else { return nil }
        guard let blob = entitlementsBlob(bytes, sliceOffset: slice.offset, sliceSize: slice.size) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: blob, format: nil)) as? [String: Any]
    }

    // MARK: Parsing

    private static let fatMagic: UInt32 = 0xCAFEBABE
    private static let fatMagic64: UInt32 = 0xCAFEBABF
    private static let machMagic64: UInt32 = 0xFEEDFACF
    private static let lcCodeSignature: UInt32 = 0x1D
    private static let embeddedSignatureMagic: UInt32 = 0xFADE0CC0
    private static let entitlementsSlot: UInt32 = 5

    private static func u32(_ b: [UInt8], _ at: Int, bigEndian: Bool) -> UInt32? {
        guard at >= 0, at + 4 <= b.count else { return nil }
        let value = UInt32(b[at]) | UInt32(b[at + 1]) << 8 | UInt32(b[at + 2]) << 16 | UInt32(b[at + 3]) << 24
        return bigEndian ? value.byteSwapped : value
    }

    private static func u64(_ b: [UInt8], _ at: Int, bigEndian: Bool) -> UInt64? {
        guard let low = u32(b, at, bigEndian: false), let high = u32(b, at + 4, bigEndian: false) else { return nil }
        let value = UInt64(low) | UInt64(high) << 32
        return bigEndian ? value.byteSwapped : value
    }

    /// Offset and size of the 64-bit Mach-O to read.
    private static func firstSlice(_ b: [UInt8]) -> (offset: Int, size: Int)? {
        guard let magic = u32(b, 0, bigEndian: true) else { return nil }
        guard magic == fatMagic || magic == fatMagic64 else { return (0, b.count) }
        // Fat headers are big-endian.
        guard let count = u32(b, 4, bigEndian: true), count > 0, count < 64 else { return nil }
        let entrySize = magic == fatMagic64 ? 32 : 20
        for index in 0..<Int(count) {
            let entry = 8 + index * entrySize
            let offset: Int, size: Int
            if magic == fatMagic64 {
                guard let o = u64(b, entry + 8, bigEndian: true), let s = u64(b, entry + 16, bigEndian: true) else { return nil }
                offset = Int(clamping: o); size = Int(clamping: s)
            } else {
                guard let o = u32(b, entry + 8, bigEndian: true), let s = u32(b, entry + 12, bigEndian: true) else { return nil }
                offset = Int(o); size = Int(s)
            }
            guard offset >= 0, size > 0, offset <= b.count, size <= b.count - offset else { continue }
            if u32(b, offset, bigEndian: false) == machMagic64 { return (offset, size) }
        }
        return nil
    }

    private static func entitlementsBlob(_ b: [UInt8], sliceOffset: Int, sliceSize: Int) -> Data? {
        let base = sliceOffset
        guard u32(b, base, bigEndian: false) == machMagic64,
              let commandCount = u32(b, base + 16, bigEndian: false),
              let commandsSize = u32(b, base + 20, bigEndian: false),
              32 + Int(commandsSize) <= sliceSize else { return nil }

        var cursor = base + 32
        let end = cursor + Int(commandsSize)
        var signature: (offset: Int, size: Int)?
        for _ in 0..<commandCount {
            guard cursor + 8 <= end,
                  let command = u32(b, cursor, bigEndian: false),
                  let size = u32(b, cursor + 4, bigEndian: false), size >= 8, cursor + Int(size) <= end else { return nil }
            if command == lcCodeSignature, size >= 16,
               let dataOffset = u32(b, cursor + 8, bigEndian: false),
               let dataSize = u32(b, cursor + 12, bigEndian: false) {
                signature = (Int(dataOffset), Int(dataSize))
                break
            }
            cursor += Int(size)
        }
        guard let signature, signature.offset <= sliceSize, signature.size <= sliceSize - signature.offset else { return nil }

        // The code signature superblob is big-endian.
        let blob = base + signature.offset
        guard u32(b, blob, bigEndian: true) == embeddedSignatureMagic,
              let count = u32(b, blob + 8, bigEndian: true),
              Int(count) <= (signature.size - 12) / 8 else { return nil }
        for index in 0..<Int(count) {
            let entry = blob + 12 + index * 8
            guard let type = u32(b, entry, bigEndian: true), type == entitlementsSlot,
                  let offset = u32(b, entry + 4, bigEndian: true) else { continue }
            let start = blob + Int(offset)
            guard Int(offset) + 8 <= signature.size,
                  let length = u32(b, start + 4, bigEndian: true),
                  length > 8, Int(offset) + Int(length) <= signature.size else { return nil }
            return Data(b[(start + 8)..<(start + Int(length))])
        }
        return nil
    }
}
