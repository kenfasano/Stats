//
//  IOReportGPU.swift
//  Stats
//
//  Reads live GPU clock frequency using Apple's private IOReport framework, the same
//  mechanism `powermetrics` uses. Unlike SMC, this doesn't require root.
//
//  Two pieces:
//  1. The GPU's DVFS frequency table (Hz per performance state), read from the "sgx"
//     IORegistry node's "perf-states" property.
//  2. A live subscription to the "GPU Stats" / "GPU Performance States" IOReport channel,
//     which reports time-residency per performance state. Averaging residency-weighted
//     frequency over a sample window gives the real current GPU clock.
//

import Foundation
import IOKit

final class IOReportGPU {
    private typealias CopyChannelsInGroup_t = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> CFMutableDictionary?
    private typealias CreateSubscription_t = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private typealias CreateSamples_t = @convention(c) (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> CFDictionary?
    private typealias CreateSamplesDelta_t = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> CFDictionary?
    private typealias ChannelGetSubGroup_t = @convention(c) (CFDictionary) -> CFString?
    private typealias StateGetCount_t = @convention(c) (CFDictionary) -> Int32
    private typealias StateGetNameForIndex_t = @convention(c) (CFDictionary, Int32) -> CFString?
    private typealias StateGetResidency_t = @convention(c) (CFDictionary, Int32) -> Int64

    private let copyChannelsInGroup: CopyChannelsInGroup_t
    private let createSubscription: CreateSubscription_t
    private let createSamples: CreateSamples_t
    private let createSamplesDelta: CreateSamplesDelta_t
    private let channelGetSubGroup: ChannelGetSubGroup_t
    private let stateGetCount: StateGetCount_t
    private let stateGetNameForIndex: StateGetNameForIndex_t
    private let stateGetResidency: StateGetResidency_t

    private let subscription: UnsafeMutableRawPointer
    private let subscribedChannels: CFMutableDictionary
    private var previousSample: CFDictionary?

    /// freqTableMHz[i] is the clock speed (MHz) for performance state "Pi" (index 0 = OFF, 0 MHz).
    private let freqTableMHz: [Double]

    init?() {
        guard let handle = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }
        guard let copyChannelsInGroup = sym("IOReportCopyChannelsInGroup", CopyChannelsInGroup_t.self),
              let createSubscription = sym("IOReportCreateSubscription", CreateSubscription_t.self),
              let createSamples = sym("IOReportCreateSamples", CreateSamples_t.self),
              let createSamplesDelta = sym("IOReportCreateSamplesDelta", CreateSamplesDelta_t.self),
              let channelGetSubGroup = sym("IOReportChannelGetSubGroup", ChannelGetSubGroup_t.self),
              let stateGetCount = sym("IOReportStateGetCount", StateGetCount_t.self),
              let stateGetNameForIndex = sym("IOReportStateGetNameForIndex", StateGetNameForIndex_t.self),
              let stateGetResidency = sym("IOReportStateGetResidency", StateGetResidency_t.self) else { return nil }

        self.copyChannelsInGroup = copyChannelsInGroup
        self.createSubscription = createSubscription
        self.createSamples = createSamples
        self.createSamplesDelta = createSamplesDelta
        self.channelGetSubGroup = channelGetSubGroup
        self.stateGetCount = stateGetCount
        self.stateGetNameForIndex = stateGetNameForIndex
        self.stateGetResidency = stateGetResidency

        guard let table = Self.readGPUFrequencyTableMHz() else { return nil }
        self.freqTableMHz = table

        guard let channels = copyChannelsInGroup("GPU Stats" as CFString, nil, 0, 0, 0) else { return nil }
        var subbedOpt: Unmanaged<CFMutableDictionary>?
        guard let sub = createSubscription(nil, channels, &subbedOpt, 0, nil),
              let subbed = subbedOpt?.takeRetainedValue() else { return nil }
        self.subscription = sub
        self.subscribedChannels = subbed
    }

    /// Call periodically (e.g. once per monitoring tick). Returns the residency-weighted
    /// average GPU frequency (MHz) since the previous call, or nil if there's no new data yet.
    func sampleFrequencyMHz() -> Double? {
        guard let current = createSamples(subscription, subscribedChannels, nil) else { return nil }
        defer { previousSample = current }
        guard let previous = previousSample,
              let delta = createSamplesDelta(previous, current, nil) else { return nil }
        return averageFrequencyMHz(delta: delta)
    }

    private func averageFrequencyMHz(delta: CFDictionary) -> Double? {
        let dict = delta as NSDictionary
        guard let channels = dict["IOReportChannels"] as? NSArray else { return nil }
        for item in channels {
            let ch = item as! CFDictionary
            guard channelGetSubGroup(ch) as String? == "GPU Performance States" else { continue }

            let count = stateGetCount(ch)
            var weightedSum = 0.0
            var totalResidency = 0.0
            for j in 0..<count {
                let name = stateGetNameForIndex(ch, j) as String? ?? ""
                let residency = Double(stateGetResidency(ch, j))
                guard residency > 0 else { continue }

                let freqIndex: Int?
                if name == "OFF" { freqIndex = 0 }
                else if name.hasPrefix("P"), let idx = Int(name.dropFirst()) { freqIndex = idx }
                else { freqIndex = nil }

                guard let fi = freqIndex, fi < freqTableMHz.count else { continue }
                weightedSum += freqTableMHz[fi] * residency
                totalResidency += residency
            }
            guard totalResidency > 0 else { return nil }
            return weightedSum / totalResidency
        }
        return nil
    }

    /// Reads the GPU's DVFS table from the "sgx" IORegistry node: pairs of (frequency Hz,
    /// voltage mV), one per performance state, starting with the OFF state (0 Hz) at index 0.
    private static func readGPUFrequencyTableMHz() -> [Double]? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("sgx"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let perfStatesRef = IORegistryEntryCreateCFProperty(service, "perf-states" as CFString, kCFAllocatorDefault, 0),
              let numStatesRef = IORegistryEntryCreateCFProperty(service, "gpu-num-perf-states" as CFString, kCFAllocatorDefault, 0),
              let perfStatesData = perfStatesRef.takeRetainedValue() as? Data,
              let numStatesData = numStatesRef.takeRetainedValue() as? Data,
              numStatesData.count >= 4 else { return nil }

        let numStates = numStatesData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let pairCount = min(Int(numStates) + 1, perfStatesData.count / 8)
        guard pairCount > 0 else { return nil }

        var freqs: [Double] = []
        for i in 0..<pairCount {
            let offset = i * 8
            let freqHz = perfStatesData.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.load(as: UInt32.self) }
            freqs.append(Double(freqHz) / 1_000_000.0)
        }
        return freqs
    }
}
