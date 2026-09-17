import Foundation

/// Per-remote-address admission bookkeeping for `docs/adr/0006-connection-and-rate-limits.md`'s
/// two additional limits (a concurrent-connection cap and a rolling-window
/// rate cap). Pulled out of `HTTPServer` as a plain, synchronous,
/// non-actor, non-networked type specifically so the admission *decision*
/// itself can be unit-tested deterministically — sequential calls with an
/// injected clock — instead of needing real concurrent network connections
/// to race against each other in wall-clock time, which is exactly what
/// made an earlier version of this logic's test flaky (and, when "fixed"
/// with an artificial per-connection delay, briefly introduced a worse bug:
/// blocking a Swift concurrency cooperative-pool thread for that delay,
/// which starved unrelated concurrent work in the same process under CI).
struct AddressConnectionTracker {
    private var connectionIDsByAddress: [String: Set<UUID>] = [:]
    private var addressByConnectionID: [UUID: String] = [:]
    private var recentConnectionTimestampsByAddress: [String: [Date]] = [:]

    private let maxConnectionsPerAddress: Int
    private let maxConnectionsPerAddressPerWindow: Int
    private let addressRateWindow: TimeInterval
    private let now: () -> Date

    init(
        maxConnectionsPerAddress: Int,
        maxConnectionsPerAddressPerWindow: Int,
        addressRateWindow: TimeInterval,
        now: @escaping () -> Date = Date.init
    ) {
        self.maxConnectionsPerAddress = maxConnectionsPerAddress
        self.maxConnectionsPerAddressPerWindow = maxConnectionsPerAddressPerWindow
        self.addressRateWindow = addressRateWindow
        self.now = now
    }

    /// Checks `address` against both caps and, if under both, registers
    /// `id` as an open connection from it. Returns `false` (and registers
    /// nothing) the moment either cap is met.
    mutating func tryAdmit(id: UUID, address: String) -> Bool {
        pruneExpiredTimestamps(for: address)
        let concurrentCount = connectionIDsByAddress[address]?.count ?? 0
        let recentCount = recentConnectionTimestampsByAddress[address]?.count ?? 0
        guard concurrentCount < maxConnectionsPerAddress,
              recentCount < maxConnectionsPerAddressPerWindow else {
            return false
        }
        recentConnectionTimestampsByAddress[address, default: []].append(now())
        connectionIDsByAddress[address, default: []].insert(id)
        addressByConnectionID[id] = address
        return true
    }

    /// Marks `id`'s connection as closed, freeing its concurrent-cap slot.
    /// The rate-window timestamp it consumed is left alone — that budget is
    /// spent for the window regardless of how long the connection lasted.
    mutating func remove(_ id: UUID) {
        guard let address = addressByConnectionID.removeValue(forKey: id) else { return }
        connectionIDsByAddress[address]?.remove(id)
        if connectionIDsByAddress[address]?.isEmpty ?? false {
            connectionIDsByAddress.removeValue(forKey: address)
        }
    }

    mutating func removeAll() {
        connectionIDsByAddress.removeAll()
        addressByConnectionID.removeAll()
        recentConnectionTimestampsByAddress.removeAll()
    }

    /// Drops timestamps older than `addressRateWindow`, and the address's
    /// own dictionary entry entirely once none remain — keeping
    /// `recentConnectionTimestampsByAddress` bounded to addresses actually
    /// active within the window, not every address ever seen.
    private mutating func pruneExpiredTimestamps(for address: String) {
        guard let timestamps = recentConnectionTimestampsByAddress[address] else { return }
        let cutoff = now().addingTimeInterval(-addressRateWindow)
        let kept = timestamps.filter { $0 >= cutoff }
        if kept.isEmpty {
            recentConnectionTimestampsByAddress.removeValue(forKey: address)
        } else {
            recentConnectionTimestampsByAddress[address] = kept
        }
    }
}
