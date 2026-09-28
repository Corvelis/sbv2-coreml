import Foundation
import SBV2Native

final class StyleVectorLoader {
    struct NpyInfo {
        let dataOffset: Int
        let numStyles: Int
        let vectorDim: Int
        let byteOrder: ByteOrder
        let data: Data
    }

    enum ByteOrder {
        case little
        case big
    }

    static func loadStyleVector(filePath: String, styleIndex: Int) -> [Float]? {
        guard let npy = parseNpy(filePath: filePath) else {
            return nil
        }

        guard styleIndex < npy.numStyles else {
            return nil
        }
        guard npy.vectorDim == 256 else {
            return nil
        }

        let bytesPerFloat = 4
        let offset = npy.dataOffset + (styleIndex * npy.vectorDim * bytesPerFloat)
        let length = npy.vectorDim * bytesPerFloat
        guard offset + length <= npy.data.count else {
            return nil
        }

        let slice = npy.data.subdata(in: offset..<offset+length)
        return decodeFloat32(data: slice, byteOrder: npy.byteOrder)
    }

    static func getNumStyles(filePath: String) -> Int {
        return parseNpy(filePath: filePath)?.numStyles ?? -1
    }

    private static func parseNpy(filePath: String) -> NpyInfo? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return nil
        }
        if data.count < 10 { return nil }
        let magic = [UInt8](data.prefix(6))
        if magic != [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59] {
            return nil
        }
        let major = data[6]
        let headerLen: Int
        let headerStart: Int
        if major == 1 {
            headerLen = Int(UInt16(littleEndian: data.subdata(in: 8..<10).withUnsafeBytes { $0.load(as: UInt16.self) }))
            headerStart = 10
        } else {
            headerLen = Int(UInt32(littleEndian: data.subdata(in: 8..<12).withUnsafeBytes { $0.load(as: UInt32.self) }))
            headerStart = 12
        }
        let headerEnd = headerStart + headerLen
        guard headerEnd <= data.count else { return nil }
        let headerData = data.subdata(in: headerStart..<headerEnd)
        let header = String(data: headerData, encoding: .ascii) ?? ""

        let shapeRegex = try? NSRegularExpression(pattern: "'shape'\\s*:\\s*\\((\\d+),\\s*(\\d+)\\)")
        guard
            let shapeRegex,
            let shapeMatch = shapeRegex.firstMatch(in: header, range: NSRange(header.startIndex..<header.endIndex, in: header)),
            let numStylesRange = Range(shapeMatch.range(at: 1), in: header),
            let vectorDimRange = Range(shapeMatch.range(at: 2), in: header),
            let numStyles = Int(header[numStylesRange].trimmingCharacters(in: .whitespaces)),
            let vectorDim = Int(header[vectorDimRange].trimmingCharacters(in: .whitespaces))
        else {
            return nil
        }

        let dtypeRegex = try? NSRegularExpression(pattern: "'descr'\\s*:\\s*'([<>|=])([a-z]\\d+)'")
        guard
            let dtypeRegex,
            let dtypeMatch = dtypeRegex.firstMatch(in: header, range: NSRange(header.startIndex..<header.endIndex, in: header)),
            let orderRange = Range(dtypeMatch.range(at: 1), in: header),
            let dtypeRange = Range(dtypeMatch.range(at: 2), in: header)
        else {
            return nil
        }
        let byteOrderSymbol = header[orderRange].first ?? "<"
        let dtype = String(header[dtypeRange])
        guard dtype == "f4" else { return nil }
        let byteOrder: ByteOrder
        switch byteOrderSymbol {
        case ">": byteOrder = .big
        default: byteOrder = .little
        }

        return NpyInfo(
            dataOffset: headerEnd,
            numStyles: numStyles,
            vectorDim: vectorDim,
            byteOrder: byteOrder,
            data: data
        )
    }

    private static func decodeFloat32(data: Data, byteOrder: ByteOrder) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(data.count / 4)
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            let count = data.count / 4
            for i in 0..<count {
                let base = i * 4
                let bytes = [ptr[base], ptr[base + 1], ptr[base + 2], ptr[base + 3]]
                let value: Float
                if byteOrder == .little {
                    value = bytes.withUnsafeBytes { $0.load(as: Float.self) }
                } else {
                    let swapped = [bytes[3], bytes[2], bytes[1], bytes[0]]
                    value = swapped.withUnsafeBytes { $0.load(as: Float.self) }
                }
                result.append(value)
            }
        }
        return result
    }
}
