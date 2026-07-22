//
//  SMCClient.swift
//  Stats
//
//  Minimal client for Apple's private SMC (System Management Controller) interface,
//  used to read hardware sensors (temperature, power) that aren't exposed by public IOKit APIs.
//

import Foundation
import IOKit

final class SMCClient {
    // Layout verified against the real C `SMCKeyData_t` struct on this toolchain via
    // __builtin_offsetof: total size 80 bytes. Using raw byte offsets (rather than a
    // hand-mirrored Swift struct) avoids relying on Swift matching C struct padding rules.
    private static let structSize = 80
    private static let offKey = 0
    private static let offKeyInfoDataSize = 28
    private static let offKeyInfoDataType = 32
    private static let offResult = 40
    private static let offData8 = 42
    private static let offBytes = 48

    private static let kSMCHandleYPCEvent: UInt32 = 2
    private static let kSMCReadKeyInfo: UInt8 = 9
    private static let kSMCReadBytes: UInt8 = 5

    private var connection: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        guard result == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Reads an SMC key (e.g. "PSTR", "Tp2a") and returns its decoded value, or nil if unavailable.
    func readValue(_ key: String) -> Double? {
        var infoInput = [UInt8](repeating: 0, count: Self.structSize)
        Self.putUInt32(&infoInput, Self.offKey, Self.fourCharCode(key))
        infoInput[Self.offData8] = Self.kSMCReadKeyInfo
        guard let infoOutput = call(infoInput), infoOutput[Self.offResult] == 0 else { return nil }

        let dataSize = Self.getUInt32(infoOutput, Self.offKeyInfoDataSize)
        let dataType = Self.getUInt32(infoOutput, Self.offKeyInfoDataType)

        var readInput = [UInt8](repeating: 0, count: Self.structSize)
        Self.putUInt32(&readInput, Self.offKey, Self.fourCharCode(key))
        Self.putUInt32(&readInput, Self.offKeyInfoDataSize, dataSize)
        readInput[Self.offData8] = Self.kSMCReadBytes
        guard let readOutput = call(readInput), readOutput[Self.offResult] == 0 else { return nil }

        let bytes = Array(readOutput[Self.offBytes..<(Self.offBytes + 32)])
        return Self.decode(type: dataType, bytes: bytes)
    }

    /// Averages the first value found among a list of candidate keys (useful since exact
    /// sensor key names vary across Apple Silicon chip generations).
    func averageValue(candidates: [String]) -> Double? {
        let values = candidates.compactMap { readValue($0) }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var input = input
        var output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let kr = input.withUnsafeMutableBytes { inPtr -> kern_return_t in
            output.withUnsafeMutableBytes { outPtr -> kern_return_t in
                IOConnectCallStructMethod(connection, Self.kSMCHandleYPCEvent,
                                           inPtr.baseAddress, Self.structSize,
                                           outPtr.baseAddress, &outputSize)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return output
    }

    private static func fourCharCode(_ key: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in key.utf8 { result = (result << 8) | UInt32(byte) }
        return result
    }

    private static func putUInt32(_ buf: inout [UInt8], _ offset: Int, _ value: UInt32) {
        buf[offset]   = UInt8(value & 0xFF)
        buf[offset+1] = UInt8((value >> 8) & 0xFF)
        buf[offset+2] = UInt8((value >> 16) & 0xFF)
        buf[offset+3] = UInt8((value >> 24) & 0xFF)
    }

    private static func getUInt32(_ buf: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(buf[offset]) | (UInt32(buf[offset+1]) << 8) | (UInt32(buf[offset+2]) << 16) | (UInt32(buf[offset+3]) << 24)
    }

    private static func decode(type: UInt32, bytes: [UInt8]) -> Double? {
        let typeChars: [UInt8] = [UInt8((type >> 24) & 0xFF), UInt8((type >> 16) & 0xFF), UInt8((type >> 8) & 0xFF), UInt8(type & 0xFF)]
        let typeStr = String(bytes: typeChars, encoding: .ascii) ?? ""

        switch typeStr {
        case "flt ":
            let raw = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: raw))
        case "sp78":
            let intPart = Int8(bitPattern: bytes[0])
            return Double(intPart) + Double(bytes[1]) / 256.0
        case "ui8 ":
            return Double(bytes[0])
        case "ui16":
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32":
            return Double((UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3]))
        default:
            return nil
        }
    }
}
