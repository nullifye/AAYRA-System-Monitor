import DiskArbitration
import Foundation

/// A mounted volume other than the startup disk: an external drive, a second internal
/// volume, a disk image or a network share.
struct VolumeStats: Equatable, Identifiable {
    enum Kind: Equatable { case internalDisk, external, diskImage, network }

    var id: String { url.path }
    let url: URL
    var name: String
    var kind: Kind
    var connection: String?  // "USB", "Thunderbolt", "SD card", "SMB", … when known
    var total: Int64
    var available: Int64
    var format: String?  // "APFS", "ExFAT", …
    var isEjectable: Bool
    var isReadOnly: Bool

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    var symbol: String {
        switch kind {
        case .internalDisk: "internaldrive.fill"
        case .external: "externaldrive.fill"
        case .diskImage: "opticaldiscdrive.fill"
        case .network: "server.rack"
        }
    }

    var kindName: String {
        switch kind {
        case .internalDisk: "Internal"
        case .external: "External"
        case .diskImage: "Disk Image"
        case .network: "Network"
        }
    }
}

/// Lists the volumes Finder shows in its sidebar, except the startup disk (that has its own card).
enum VolumeProvider {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey, .volumeLocalizedFormatDescriptionKey,
        .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
        .volumeIsBrowsableKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
    ]

    /// One Disk Arbitration session for the app's lifetime.
    private static let session = DASessionCreate(kCFAllocatorDefault)

    static func sample() -> [VolumeStats] {
        let urls =
            FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys,
                options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> VolumeStats? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                values.volumeIsRootFileSystem != true,
                values.volumeIsBrowsable != false,
                !url.path.hasPrefix("/System/Volumes"),
                let total = values.volumeTotalCapacity, total > 0
            else { return nil }

            let free = Int64(values.volumeAvailableCapacity ?? 0)
            // "Important usage" counts purgeable space like Finder; network shares don't report it.
            let available =
                values.volumeIsLocal == false
                ? free
                : max(values.volumeAvailableCapacityForImportantUsage ?? free, free)
            let disk = session.flatMap { diskInfo(for: url, session: $0) }

            let kind: VolumeStats.Kind
            if values.volumeIsLocal == false {
                kind = .network
            } else if disk?.isDiskImage == true {
                kind = .diskImage
            } else if values.volumeIsInternal == true {
                kind = .internalDisk
            } else {
                kind = .external
            }
            return VolumeStats(
                url: url,
                name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
                kind: kind,
                connection: kind == .network ? url.scheme?.uppercased() : disk?.connection,
                total: Int64(total),
                available: available,
                format: values.volumeLocalizedFormatDescription,
                isEjectable: values.volumeIsEjectable == true || values.volumeIsRemovable == true || kind == .network,
                isReadOnly: values.volumeIsReadOnly == true)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// How the drive is connected, from Disk Arbitration (e.g. "USB", "Thunderbolt", "Disk Image").
    private static func diskInfo(for url: URL, session: DASession) -> (connection: String?, isDiskImage: Bool)? {
        guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
            let info = DADiskCopyDescription(disk) as? [String: Any]
        else { return nil }
        let model = info[kDADiskDescriptionDeviceModelKey as String] as? String
        let proto = info[kDADiskDescriptionDeviceProtocolKey as String] as? String
        let isDiskImage =
            model?.localizedCaseInsensitiveContains("Disk Image") == true
            || proto == "Virtual Interface"
        let connection: String? =
            switch proto {
            case "Virtual Interface", nil: nil
            case "Secure Digital": "SD card"
            case let other?: other
            }
        return (connection, isDiskImage)
    }
}
