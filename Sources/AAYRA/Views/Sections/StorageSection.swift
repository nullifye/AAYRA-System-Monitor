import AppKit
import SwiftUI

// Storage: the card in the panel and its detail panel, including other volumes.

struct StorageCard: View {
    let disk: DiskStats
    let io: DiskIO
    let volumes: [VolumeStats]

    var body: some View {
        Card(symbol: "internaldrive.fill", tint: Palette.storage) {
            MeterHeader(title: "Storage", value: Format.diskShort(disk.available), suffix: "free")
        } details: {
            StackedBar(
                segments: [
                    .init(value: share(disk.used), color: Palette.storage),
                    .init(value: share(disk.purgeable), color: Palette.storagePurgeable),
                ], height: 8)
            StatRow(stats: [
                Stat(label: "Used", value: Format.diskShort(disk.used), dot: Palette.storage),
                Stat(label: "Purge.", value: Format.diskShort(disk.purgeable), dot: Palette.storagePurgeable),
                Stat(label: "Total", value: Format.diskShort(disk.total)),
            ])
            // Live disk activity, in the same columns as the line above.
            StatRow(stats: [
                Stat(label: "Read", value: Format.compactRate(io.readBytesPerSec), dot: Palette.diskRead),
                Stat(label: "Write", value: Format.compactRate(io.writeBytesPerSec), dot: Palette.diskWrite),
                Stat(label: "", value: ""),
            ])
            // Other mounted volumes (external drives, disk images, network shares), two at most.
            ForEach(volumes.prefix(2)) { volume in
                HStack(spacing: 5) {
                    Image(systemName: volume.symbol)
                        .font(.caption)
                        .frame(width: 14)
                    Text(volume.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text("\(Format.diskShort(volume.available)) free")
                        .foregroundStyle(.primary)
                        .monospacedDigit()
                }
            }
            if volumes.count > 2 {
                Text("+\(volumes.count - 2) more volumes")
            }
        }
    }

    private func share(_ bytes: Int64) -> Double {
        disk.total > 0 ? Double(bytes) / Double(disk.total) : 0
    }
}

struct StorageDetail: View {
    let monitor: SystemMonitor
    private var disk: DiskStats { monitor.disk }
    private var ssd: SSDHealth? { monitor.ssd }

    var body: some View {
        let io = monitor.diskIO
        DetailPanel(
            symbol: "internaldrive.fill", tint: Palette.storage, title: "Storage", subtitle: subtitle,
            actions: [
                DetailAction(title: "Manage Storage…", symbol: "gearshape") {
                    SystemActions.openSettings(.storage)
                }
            ]
        ) {
            DetailSection("Space") {
                StackedBar(
                    segments: [
                        .init(value: share(disk.used), color: Palette.storage),
                        .init(value: share(disk.purgeable), color: Palette.storagePurgeable),
                    ], height: 8
                )
                .padding(.vertical, 3)
                DetailRow("Used", Format.diskBytes(disk.used), dot: Palette.storage)
                DetailRow("Purgeable", Format.diskBytes(disk.purgeable), dot: Palette.storagePurgeable)
                DetailRow("Free", Format.diskBytes(disk.free))
                DetailRow("Available", Format.diskBytes(disk.available))
                DetailRow("Total", Format.diskBytes(disk.total))
            }
            DetailSection("Disk Activity") {
                DualSparkline(download: monitor.diskReadHistory, upload: monitor.diskWriteHistory, height: 34)
                    .padding(.vertical, 2)
                DetailRow("Read", Format.rate(io.readBytesPerSec), dot: Palette.diskRead)
                DetailRow("Write", Format.rate(io.writeBytesPerSec), dot: Palette.diskWrite)
                let span = Format.span(monitor.historySpan)
                DetailRow("Peak read (\(span))", Format.rate(monitor.diskReadHistory.max() ?? 0))
                DetailRow("Peak write (\(span))", Format.rate(monitor.diskWriteHistory.max() ?? 0))
                DetailRow("Read since boot", Format.diskBytes(Int64(clamping: io.totalRead)))
                DetailRow("Written since boot", Format.diskBytes(Int64(clamping: io.totalWritten)))
            }
            if let ssd {
                DetailSection("Lifetime I/O") {
                    DetailRow("Written", Format.diskBytes(Int64(clamping: ssd.bytesWritten)))
                    DetailRow("Read", Format.diskBytes(Int64(clamping: ssd.bytesRead)))
                }
            }
        } trailing: {
            if let ssd {
                let info = ssd.info
                DetailSection("Drive") {
                    if let model = info.model { DetailRow("Model", model) }
                    if let capacity = info.capacityBytes { DetailRow("Capacity", Format.diskBytes(capacity)) }
                    if let interconnect = info.interconnect { DetailRow("Interface", interconnect) }
                    if let bsd = info.bsdName { DetailRow("Device", bsd) }
                    if let serial = info.serial { DetailRow("Serial", serial, placeholder: "0123456789ABCDEF") }
                    if let firmware = info.firmware { DetailRow("Firmware", firmware) }
                }
                DetailSection("Health") {
                    DetailRow("Health", Format.percent(ssd.health), dot: ssd.healthColor)
                    DetailRow("Condition", ssd.condition)
                    DetailRow("Spare", "\(ssd.availableSpare)% (min \(ssd.availableSpareThreshold)%)")
                    if let t = ssd.temperatureC { DetailRow("Temperature", Format.temperature(celsius: t)) }
                    DetailRow(
                        "Power-on", "\(ssd.powerOnHours.formatted()) h (\(Int((Double(ssd.powerOnHours) / 24).rounded())) days)")
                    DetailRow("Power cycles", ssd.powerCycles.formatted())
                    DetailRow("Unsafe shutdowns", ssd.unsafeShutdowns.formatted())
                    DetailRow("Media errors", ssd.mediaErrors.formatted())
                }
            } else {
                DetailSection("Drive") { EmptyRow(text: "SMART data unavailable") }
            }
            DetailSection("Volume") {
                DetailRow("Name", disk.volumeName)
                if let format = disk.fileSystem { DetailRow("Format", format) }
                if let encrypted = disk.isEncrypted { DetailRow("FileVault", Format.onOff(encrypted)) }
            }
            DetailSection("Other Volumes") {
                if monitor.volumes.isEmpty {
                    EmptyRow(text: "No external drives connected")
                }
                ForEach(monitor.volumes) { volume in
                    VolumeRow(volume: volume) { monitor.eject(volume) }
                }
                if let message = monitor.volumeMessage {
                    Text(message).font(.callout).foregroundStyle(.orange)
                }
            }
        }
    }

    private var subtitle: String {
        "\(Format.diskBytes(disk.available)) available of \(Format.diskBytes(disk.total))"
    }

    private func share(_ bytes: Int64) -> Double {
        disk.total > 0 ? Double(bytes) / Double(disk.total) : 0
    }
}

/// One mounted volume: name with its kind and connection, a usage bar, free space and format.
/// Click to open it in Finder; ejectable volumes get an eject button.
private struct VolumeRow: View {
    let volume: VolumeStats
    let onEject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: volume.symbol)
                    .foregroundStyle(Palette.storage)
                    .frame(width: 18)
                Text(volume.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(([volume.kindName, volume.connection].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if volume.isEjectable {
                    Button(action: onEject) {
                        Image(systemName: "eject.fill")
                    }
                    .buttonStyle(.borderless)
                    .help("Eject “\(volume.name)”")
                    .accessibilityLabel("Eject \(volume.name)")
                }
            }
            StackedBar(segments: [.init(value: volume.usedFraction, color: Palette.storage)], height: 6)
            HStack {
                Text("\(Format.diskBytes(volume.available)) free of \(Format.diskBytes(volume.total))")
                    .monospacedDigit()
                Spacer(minLength: 8)
                Text(([volume.format, volume.isReadOnly ? "Read-only" : nil].compactMap { $0 }).joined(separator: " · "))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .font(.body)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(volume.url) }
        .help("Open in Finder")
    }
}

extension SSDHealth {
    var healthColor: Color {
        if condition == "Check Drive" { return .red }
        return health >= 0.8 ? .green : health >= 0.5 ? .orange : .red
    }
}
