import Foundation
import Network
import os

/// Browses for Apple TVs and publishes the current list whenever it changes.
///
/// The actor runs on the same serial queue as its NWBrowser and NWPathMonitor, so their
/// callbacks can update state directly and in order.
public actor DeviceBrowser {
    public static let serviceType = "_companion-link._tcp"

    nonisolated let queue = DispatchSerialQueue(label: "Clickr.DeviceBrowser")
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    private let log = Logger(subsystem: "com.ziggy46.clickr", category: "Discovery")
    private var browser: NWBrowser?
    private var pathMonitor: NWPathMonitor?
    private var lastPath: PathSignature?
    private var isRunning = false
    private var current: [DiscoveredDevice] = []
    private var continuations: [UUID: AsyncStream<[DiscoveredDevice]>.Continuation] = [:]

    public init() {}

    /// A stream of the full device list. Yields the current list right away, then every change.
    public var devices: AsyncStream<[DiscoveredDevice]> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: [DiscoveredDevice].self,
            bufferingPolicy: .bufferingNewest(1)
        )
        let id = UUID()
        continuations[id] = continuation
        continuation.yield(current)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(id) }
        }
        return stream
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        startPathMonitor()
        startBrowser()
    }

    public func stop() {
        isRunning = false
        browser?.cancel()
        browser = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPath = nil
        publish([])
    }

    // MARK: - Browsing

    private func startBrowser() {
        let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(type: Self.serviceType, domain: "local.")
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: descriptor, using: parameters)

        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser else { return }
            self.assumeIsolated { $0.browserStateChanged(state, browser: browser) }
        }
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser else { return }
            self.assumeIsolated { $0.resultsChanged(results, browser: browser) }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func restartBrowser() {
        browser?.cancel()
        browser = nil
        publish([])
        startBrowser()
    }

    private func browserStateChanged(_ state: NWBrowser.State, browser: NWBrowser) {
        guard browser === self.browser else { return }
        switch state {
        case .failed(let error):
            log.error("Browser failed: \(String(describing: error), privacy: .public). Restarting.")
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.assumeIsolated { me in
                    if me.isRunning && me.browser === browser { me.restartBrowser() }
                }
            }
        case .waiting(let error):
            // Usually means Local Network access was denied.
            log.error("Browser waiting: \(String(describing: error), privacy: .public)")
        default:
            break
        }
    }

    private func resultsChanged(_ results: Set<NWBrowser.Result>, browser: NWBrowser) {
        guard browser === self.browser else { return }
        let records = results.compactMap { result -> BrowseRecord? in
            guard case .service(let name, _, _, let interface) = result.endpoint else { return nil }
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata {
                txt = record.dictionary
            }
            return BrowseRecord(name: name, interfaceName: interface?.name, endpoint: result.endpoint, txt: txt)
        }
        publish(Self.devices(from: records))
    }

    // MARK: - Network changes

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.assumeIsolated { $0.pathChanged(PathSignature(path)) }
        }
        pathMonitor = monitor
        monitor.start(queue: queue)
    }

    private func pathChanged(_ signature: PathSignature) {
        defer { lastPath = signature }
        // The first update just reports the current network.
        guard let lastPath, lastPath != signature, isRunning else { return }
        log.info("Network changed, browsing again")
        restartBrowser()
    }

    // MARK: - Publishing

    private func publish(_ devices: [DiscoveredDevice]) {
        guard devices != current else { return }
        current = devices
        for continuation in continuations.values {
            continuation.yield(devices)
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations[id] = nil
    }
}

// MARK: - Pure helpers (unit tested)

struct BrowseRecord {
    let name: String
    let interfaceName: String?
    let endpoint: NWEndpoint
    let txt: [String: String]
}

extension DeviceBrowser {
    /// Turns raw browse results into the device list: keeps Apple TVs only, collapses the
    /// one-result-per-interface duplicates by service name, and sorts by name.
    static func devices(from records: [BrowseRecord]) -> [DiscoveredDevice] {
        // Results come from a Set, so sort first to keep the same interface's copy each time.
        let records = records.sorted { ($0.name, $0.interfaceName ?? "") < ($1.name, $1.interfaceName ?? "") }
        var byName: [String: DiscoveredDevice] = [:]
        for record in records where byName[record.name] == nil {
            byName[record.name] = DiscoveredDevice(name: record.name, endpoint: record.endpoint, txt: record.txt)
        }
        return byName.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// The parts of a network path that should trigger a fresh browse when they change.
struct PathSignature: Equatable {
    let status: NWPath.Status
    let interfaces: [String]

    init(_ path: NWPath) {
        status = path.status
        interfaces = path.availableInterfaces.map(\.name).sorted()
    }
}
