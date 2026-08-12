import Foundation
import IOKit

/// Walks the IORegistry once and hands back whatever accessories it found.
///
/// This is the reading half of the accessory provider, and it is deliberately
/// not main-actor isolated: `DeviceBatterySource` exists precisely so that the
/// registry walk cannot be performed from the actor that draws the panel.
///
/// The walk itself is short — a handful of services, one property dictionary
/// each — but it is synchronous C, so it runs on its own queue rather than
/// blocking a cooperative-pool thread that something else was counting on.
struct IORegistryAccessorySource: DeviceBatterySource {
    private let clock: DeviceClock
    private let resolver: DeviceIdentityResolver
    private let queue = DispatchQueue(label: "io.tumanov.impuls.accessory-registry", qos: .utility)

    init(clock: DeviceClock = SystemDeviceClock(), resolver: DeviceIdentityResolver = .shared) {
        self.clock = clock
        self.resolver = resolver
    }

    func read() async throws -> [AppleDeviceSnapshot] {
        let now = clock.now
        let resolver = self.resolver
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: Self.scan(now: now, resolver: resolver))
            }
        }
    }

    /// Collects the property dictionaries of every matching service.
    ///
    /// No accessories is the ordinary case — a Mac with nothing paired, a Mac
    /// whose Bluetooth is off — and it returns an empty list rather than an
    /// error. The same is true when the service class itself does not exist:
    /// this reads an undocumented corner of the registry, and a macOS release
    /// that reorganises it must produce an empty panel section, not a failure.
    static func scan(now: Date, resolver: DeviceIdentityResolver) -> [AppleDeviceSnapshot] {
        guard let matching = IOServiceMatching(IORegistryAccessoryMapper.serviceClass) else { return [] }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var devices: [AppleDeviceSnapshot] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let properties = properties(of: service) else { continue }
            guard let device = IORegistryAccessoryMapper.device(
                from: properties,
                now: now,
                resolver: resolver
            ) else { continue }
            devices.append(device)
        }
        return devices
    }

    /// How many services of the class exist at all, regardless of what they
    /// publish. Separates "the class is gone" from "the class is there and says
    /// nothing about batteries" — two very different findings for a QA run, and
    /// the reason phase 03's assumption could be checked rather than argued.
    static func matchingServiceCount() -> Int {
        guard let matching = IOServiceMatching(IORegistryAccessoryMapper.serviceClass) else { return 0 }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }
        var count = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
            count += 1
        }
        return count
    }

    private static func properties(of service: io_registry_entry_t) -> [String: Any]? {
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return dictionary
    }
}
