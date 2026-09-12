import Foundation
import IOKit
import IOKit.hid

/// Reads the MacBook's hinge (lid) angle straight from the built-in
/// orientation sensor, bypassing any higher-level framework.
///
/// The sensor shows up as an HID device (vendor `0x05AC`, the Apple usage
/// page `0x20`, usage `0x8A`) and answers `kIOHIDReportTypeFeature` reads
/// with the current angle. Two report shapes are known to occur:
///
///  - Feature report `0x01`: 3 bytes, `[reportID, angleLowByte, angleHighByte]`,
///    a plain little-endian `UInt16` in whole degrees.
///  - Feature report `0x07`: 5 bytes, `[reportID, b0, b1, b2, b3]`, a
///    little-endian `UInt32` in hundredths of a degree.
///
/// Not every model exposes report `0x07`; this type probes for it once at
/// open time and falls back to report `0x01`. No entitlement or user
/// permission is needed to read either report.
public final class HingeAngleSensor {

    /// The angle unit a particular device answers with, fixed once at open.
    public enum ReportKind: Sendable {
        case hundredthsOfDegree
        case wholeDegrees

        var reportID: Int {
            switch self {
            case .hundredthsOfDegree: return 7
            case .wholeDegrees: return 1
            }
        }

        var minimumByteCount: Int {
            switch self {
            case .hundredthsOfDegree: return 5
            case .wholeDegrees: return 3
            }
        }
    }

    /// Diagnostic detail from the most recent read attempt, kept around so a
    /// caller (or a diagnostics tool) can explain a failure.
    public struct LastAttempt: Sendable {
        public var status: IOReturn = kIOReturnSuccess
        public var byteCount: Int = 0
        public var rawBytes: [UInt8] = []
        public var outOfRangeValue: Double?
    }

    private static let vendorUsagePage = 0x20
    private static let vendorUsage = 0x8A
    private static let validRange: ClosedRange<Double> = 0...360

    public private(set) var lastAttempt = LastAttempt()
    public private(set) var reportKind: ReportKind?

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var scratch = [UInt8](repeating: 0, count: 32)

    /// Whether a matching sensor device was found and a report kind decided.
    public var isAvailable: Bool { device != nil && reportKind != nil }

    public init() {
        openDevice()
    }

    deinit {
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    /// The current hinge angle in degrees (0 = fully closed, roughly 130 when
    /// open flat on a lap), or `nil` if the read failed or no sensor exists.
    public func readAngleDegrees() -> Double? {
        guard let reportKind else { return nil }
        guard let bytes = readReport(id: reportKind.reportID) else { return nil }
        guard bytes.count >= reportKind.minimumByteCount else { return nil }

        let degrees: Double
        switch reportKind {
        case .hundredthsOfDegree:
            let raw = UInt32(bytes[1])
                | (UInt32(bytes[2]) << 8)
                | (UInt32(bytes[3]) << 16)
                | (UInt32(bytes[4]) << 24)
            degrees = Double(raw) / 100
        case .wholeDegrees:
            let raw = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
            degrees = Double(raw)
        }

        guard Self.validRange.contains(degrees) else {
            lastAttempt.outOfRangeValue = degrees
            return nil
        }
        return degrees
    }

    // MARK: - Device discovery

    private func openDevice() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDDeviceUsagePageKey: Self.vendorUsagePage,
            kIOHIDDeviceUsageKey: Self.vendorUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return
        }
        self.manager = manager

        guard let candidates = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !candidates.isEmpty else {
            return
        }

        for candidate in candidates {
            device = candidate
            if let probe = readReport(id: ReportKind.hundredthsOfDegree.reportID),
               probe.count >= ReportKind.hundredthsOfDegree.minimumByteCount {
                reportKind = .hundredthsOfDegree
                return
            }
            if let probe = readReport(id: ReportKind.wholeDegrees.reportID),
               probe.count >= ReportKind.wholeDegrees.minimumByteCount {
                reportKind = .wholeDegrees
                return
            }
        }
        device = nil
    }

    private func readReport(id: Int) -> [UInt8]? {
        lastAttempt = LastAttempt()
        guard let device else {
            lastAttempt.status = kIOReturnNoDevice
            return nil
        }

        var length = CFIndex(scratch.count)
        let status = scratch.withUnsafeMutableBufferPointer { buffer -> IOReturn in
            guard let base = buffer.baseAddress else { return kIOReturnBadArgument }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), base, &length)
        }

        lastAttempt.status = status
        lastAttempt.byteCount = Int(length)
        guard status == kIOReturnSuccess, length > 0 else { return nil }

        let bytes = Array(scratch[0..<Int(length)])
        lastAttempt.rawBytes = bytes
        return bytes
    }
}
