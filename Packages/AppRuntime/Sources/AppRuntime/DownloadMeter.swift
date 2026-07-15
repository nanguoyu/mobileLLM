// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import Foundation

/// Compact "~3m left" / "~12s left" / "~1h 05m left" for a download ETA.
private func formatETA(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s < 60 { return "\(max(1, s))s left" }
    if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s left" }
    return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m left"
}

/// Tracks a download's bytes / throughput / ETA from the fraction reported by the downloader plus the
/// known total size, so the UI can show "2.3 GB / 4.6 GB · 12 MB/s · ~3m left" instead of a bare bar.
/// Throughput is a smoothed (EMA) estimate sampled at most a few times a second so it doesn't jitter.
/// (Ported verbatim from MobileDiffuser — Foundation only.)
public struct DownloadMeter {
    public private(set) var totalBytes: Int64 = 0
    public private(set) var downloadedBytes: Int64 = 0
    public private(set) var bytesPerSecond: Double = 0
    private var lastSampleAt: Date?
    private var lastSampleBytes: Int64 = 0

    public init() {}

    /// Begin a new download of `total` bytes (0 ⇒ unknown total; the meter then shows nothing).
    public mutating func start(total: Int64) {
        totalBytes = max(0, total); downloadedBytes = 0; bytesPerSecond = 0
        lastSampleAt = nil; lastSampleBytes = 0
    }

    /// Feed a 0…1 fraction. Re-derives bytes and updates the smoothed throughput (sampled ≥0.4s apart).
    public mutating func update(fraction: Double, now: Date = Date()) {
        guard totalBytes > 0 else { return }
        downloadedBytes = Int64((min(max(fraction, 0), 1)) * Double(totalBytes))
        guard let last = lastSampleAt else { lastSampleAt = now; lastSampleBytes = downloadedBytes; return }
        let dt = now.timeIntervalSince(last)
        guard dt >= 0.4 else { return }
        let instantaneous = max(0, Double(downloadedBytes - lastSampleBytes)) / dt
        bytesPerSecond = bytesPerSecond == 0 ? instantaneous : bytesPerSecond * 0.6 + instantaneous * 0.4
        lastSampleAt = now; lastSampleBytes = downloadedBytes
    }

    public var etaSeconds: Double? {
        guard bytesPerSecond > 1, downloadedBytes < totalBytes else { return nil }
        return Double(totalBytes - downloadedBytes) / bytesPerSecond
    }

    /// "2.3 GB / 4.6 GB · 12 MB/s · ~3m left" — speed/ETA appear once there's a stable estimate.
    public var detail: String? {
        guard totalBytes > 0 else { return nil }
        let f = ByteCountFormatter()
        var parts = ["\(f.string(fromByteCount: downloadedBytes)) / \(f.string(fromByteCount: totalBytes))"]
        if bytesPerSecond > 1 { parts.append("\(f.string(fromByteCount: Int64(bytesPerSecond)))/s") }
        if let eta = etaSeconds { parts.append("~\(formatETA(eta))") }
        return parts.joined(separator: " · ")
    }

    /// Like `detail` but WITHOUT the total — for a narrow row that already shows the size in another
    /// column. "102.7 MB · 12 MB/s · ~3m left".
    public var compactDetail: String? {
        guard totalBytes > 0 else { return nil }
        let f = ByteCountFormatter()
        var parts = [f.string(fromByteCount: downloadedBytes)]
        if bytesPerSecond > 1 { parts.append("\(f.string(fromByteCount: Int64(bytesPerSecond)))/s") }
        if let eta = etaSeconds { parts.append("~\(formatETA(eta))") }
        return parts.joined(separator: " · ")
    }
}
