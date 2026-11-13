import CoreBluetooth
import Foundation
import Observation
import os

/// A Bluetooth heart rate monitor: a chest strap or armband, or a watch that
/// broadcasts its heart rate (such as a Garmin with Broadcast Heart Rate on).
/// Anything using the standard Bluetooth heart rate service works.
///
/// One monitor is remembered. While something is using it (between `acquire`
/// and `release`), the app keeps a connection open, reconnects whenever it
/// drops, and records every reading so a finished run can look them up.
///
/// A watch broadcasting heart rate isn't bonded to the phone, so it can turn up
/// under a new Bluetooth identifier from one session to the next. So besides
/// connecting by identifier, the app scans for the remembered monitor's name
/// until it's connected, and remembers the new identifier when it finds it.
@MainActor
@Observable
final class HeartRateMonitor {
    static let shared = HeartRateMonitor()

    enum Status: Equatable {
        case notPaired
        /// Paired, and not in use right now.
        case idle
        case connecting
        /// Sending heart rate: subscribed to its readings.
        case connected
        /// Connected, but it doesn't offer heart rate (a Garmin with Broadcast
        /// Heart Rate off), or wouldn't let the app subscribe. Picks up by itself
        /// if broadcasting is turned on.
        case noHeartRate
        case bluetoothOff
        case notAllowed
        case unavailable
    }

    /// A monitor found while searching.
    struct Found: Identifiable, Equatable {
        let id: UUID
        let name: String
    }

    static let heartRateService = CBUUID(string: "180D")
    static let measurementCharacteristic = CBUUID(string: "2A37")
    /// A reading older than this isn't shown.
    private static let staleAfter: TimeInterval = 5
    /// Readings are kept this long, longer than any workout.
    private static let keepReadingsFor: TimeInterval = 12 * 3600
    /// Shown for a monitor that doesn't say its name; never matched by name.
    private nonisolated static let unnamed = "Heart rate monitor"
    private static let pairedIDKey = "heartRateMonitorID"
    private static let pairedNameKey = "heartRateMonitorName"

    private(set) var status: Status
    private(set) var pairedName: String?
    /// The latest reading, or nil when none has arrived for a few seconds.
    private(set) var bpm: Int?
    private(set) var isSearching = false
    /// Monitors found while searching, in the order they were found.
    private(set) var found: [Found] = []
    /// Whether the connected monitor sent a reading that couldn't be used
    /// (no skin contact, or an unbelievable value) since the last reading that could.
    private(set) var skippingReadings = false

    @ObservationIgnored private let delegate = BluetoothDelegate()
    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var discovered: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var readings: [HeartRateSample] = []
    @ObservationIgnored private var staleReading: DispatchWorkItem?
    @ObservationIgnored private let log = Logger(subsystem: "IntervalRun", category: "HeartRate")

    private init() {
        pairedName = UserDefaults.standard.string(forKey: Self.pairedNameKey)
        status = UserDefaults.standard.string(forKey: Self.pairedIDKey) == nil ? .notPaired : .idle
        delegate.monitor = self
    }

    var isPaired: Bool { pairedID != nil }

    /// Whether the players show a heart rate: a monitor is connected, or being
    /// looked for, or a reading is still fresh.
    var isLive: Bool { bpm != nil || [.connected, .connecting, .noHeartRate].contains(status) }

    /// Why the players show no heart rate yet, in a few words; nil once readings arrive.
    var waitingText: String? {
        guard bpm == nil else { return nil }
        return switch status {
        case .connected: skippingReadings ? "Can't read heart rate" : "Waiting for heart rate"
        case .noHeartRate: "Not broadcasting"
        default: "Looking for monitor"
        }
    }

    /// What the players' heart rate says to VoiceOver.
    var liveAccessibilityText: String {
        if let bpm { return "Heart rate \(bpm) beats per minute" }
        return switch status {
        case .connected: "Waiting for heart rate"
        case .noHeartRate: "Heart rate monitor connected but not sending heart rate"
        default: "Looking for heart rate monitor"
        }
    }

    private var pairedID: UUID? {
        UserDefaults.standard.string(forKey: Self.pairedIDKey).flatMap(UUID.init(uuidString:))
    }

    // MARK: Using the monitor

    /// Connects to the paired monitor (if any) and keeps the connection until
    /// every caller has called `release`. Call when a run starts.
    func acquire() {
        users += 1
        if users == 1 { connectIfPaired() }
    }

    func release() {
        guard users > 0 else { return }
        users -= 1
        if users == 0 { disconnect() }
    }

    /// Readings recorded during `interval`.
    func samples(in interval: DateInterval) -> [HeartRateSample] {
        readings.filter { interval.contains($0.date) }
    }

    // MARK: Pairing

    func startSearching() {
        found = []
        isSearching = true
        makeCentral()
        scanIfReady()
    }

    func stopSearching() {
        isSearching = false
        central?.stopScan()
        if users > 0, status != .connected, status != .noHeartRate { connectIfPaired() } // keep looking for the paired one
    }

    func pair(_ monitor: Found) {
        guard let chosen = discovered[monitor.id] else { return }
        if let old = peripheral, old.identifier != chosen.identifier {
            central?.cancelPeripheralConnection(old)
        }
        UserDefaults.standard.set(chosen.identifier.uuidString, forKey: Self.pairedIDKey)
        UserDefaults.standard.set(monitor.name, forKey: Self.pairedNameKey)
        pairedName = monitor.name
        found.removeAll { $0.id == monitor.id }
        if users > 0 {
            connect(chosen)
        } else {
            peripheral = chosen
            status = .idle
        }
    }

    func forget() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        UserDefaults.standard.removeObject(forKey: Self.pairedIDKey)
        UserDefaults.standard.removeObject(forKey: Self.pairedNameKey)
        pairedName = nil
        bpm = nil
        status = .notPaired
    }

    // MARK: Connection

    /// Asking for Bluetooth shows the permission prompt the first time, so the
    /// manager is only made once a monitor is being paired or used.
    private func makeCentral() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: delegate, queue: nil)
    }

    private func connectIfPaired() {
        guard let id = pairedID else { return }
        makeCentral()
        guard let central, central.state == .poweredOn else { return } // continues in `stateChanged`
        // Already connected to the phone (say, through the watch maker's app).
        if let connected = central.retrieveConnectedPeripherals(withServices: [Self.heartRateService])
            .first(where: { isPairedMonitor($0, advertisedName: nil) }) {
            adopt(connected)
        } else if let known = peripheral ?? central.retrievePeripherals(withIdentifiers: [id]).first {
            connect(known) // completes if it's still under this identifier
        } else {
            status = .connecting
        }
        // In case it's now under a new identifier, or (like a Garmin linked to
        // Garmin Connect) the link above never sends readings and the broadcast
        // is elsewhere; `didDiscover` connects to it. Scans until a reading arrives.
        central.scanForPeripherals(withServices: [Self.heartRateService])
    }

    /// Whether a monitor seen nearby is the remembered one.
    private func isPairedMonitor(_ candidate: CBPeripheral, advertisedName: String?) -> Bool {
        Self.isSameMonitor(id: candidate.identifier, name: candidate.name ?? advertisedName,
                           pairedID: pairedID, pairedName: pairedName)
    }

    /// The same identifier, or (as identifiers can change) the same name.
    nonisolated static func isSameMonitor(id: UUID, name: String?, pairedID: UUID?, pairedName: String?) -> Bool {
        guard let pairedID else { return false }
        if id == pairedID { return true }
        guard let name, let pairedName, pairedName != unnamed else { return false }
        return name == pairedName
    }

    /// Connects to the remembered monitor found under `found`'s identifier,
    /// dropping any wait on its old identifier.
    private func adopt(_ found: CBPeripheral) {
        if found.identifier != pairedID {
            log.info("Heart rate monitor found under a new identifier")
            UserDefaults.standard.set(found.identifier.uuidString, forKey: Self.pairedIDKey)
        }
        if let old = peripheral, old.identifier != found.identifier {
            central?.cancelPeripheralConnection(old)
        }
        connect(found)
    }

    /// "Connected" waits for the subscription to heart rate readings, not just
    /// the Bluetooth link: a watch can be linked to the phone without sending any.
    private func connect(_ target: CBPeripheral) {
        peripheral = target
        skippingReadings = false
        target.delegate = delegate
        status = .connecting
        // Already linked to this app, so `didConnect` may not come again.
        if target.state == .connected { subscribe(target) }
        // Stays pending until the monitor is in range; it never times out.
        central?.connect(target)
    }

    /// Finds the heart rate measurement and asks for its readings. Always
    /// discovers afresh: services cached from an earlier connection (say, the
    /// settings screen just before a run) aren't valid on a new one.
    private func subscribe(_ target: CBPeripheral) {
        target.discoverServices([Self.heartRateService])
    }

    private func disconnect() {
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        if !isSearching { central?.stopScan() }
        bpm = nil
        if let central, central.state != .poweredOn { return } // keep showing why
        status = isPaired ? .idle : .notPaired
    }

    private func scanIfReady() {
        guard isSearching, let central, central.state == .poweredOn else { return }
        // Monitors already connected to the phone (by another app) don't advertise.
        for connected in central.retrieveConnectedPeripherals(withServices: [Self.heartRateService]) {
            add(connected, advertisedName: nil)
        }
        central.scanForPeripherals(withServices: [Self.heartRateService])
    }

    private func add(_ found: CBPeripheral, advertisedName: String?) {
        discovered[found.identifier] = found
        guard isSearching, !isPairedMonitor(found, advertisedName: advertisedName),
              !self.found.contains(where: { $0.id == found.identifier }) else { return }
        self.found.append(Found(id: found.identifier, name: found.name ?? advertisedName ?? Self.unnamed))
    }

    private func record(_ bpm: Int) {
        readings.append(HeartRateSample(date: .now, bpm: bpm))
        if let first = readings.first, first.date < .now.addingTimeInterval(-Self.keepReadingsFor) {
            readings.removeAll { $0.date < .now.addingTimeInterval(-Self.keepReadingsFor) }
        }
        self.bpm = bpm
        staleReading?.cancel()
        let stale = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.bpm = nil }
        }
        staleReading = stale
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.staleAfter, execute: stale)
    }

    // MARK: Bluetooth events

    fileprivate func stateChanged(_ state: CBManagerState) {
        switch state {
        case .poweredOn:
            status = users > 0 && isPaired ? .connecting : (isPaired ? .idle : .notPaired)
            if users > 0 { connectIfPaired() }
            scanIfReady()
        case .poweredOff, .resetting:
            status = .bluetoothOff
            bpm = nil
        case .unauthorized:
            status = .notAllowed
        case .unsupported:
            status = .unavailable
        default:
            break
        }
    }

    fileprivate func didDiscover(_ found: CBPeripheral, advertisedName: String?) {
        add(found, advertisedName: advertisedName)
        guard users > 0 else { return }
        let isPaired = isPairedMonitor(found, advertisedName: advertisedName)
        log.info("Heart rate monitor nearby: \(found.name ?? advertisedName ?? "unnamed", privacy: .public) \(found.identifier.uuidString.prefix(8), privacy: .public), paired: \(isPaired)")
        guard isPaired else { return }
        // Once subscribed, only switch if that link is silent and this is another one.
        if status == .connected, bpm != nil || found.identifier == peripheral?.identifier { return }
        adopt(found)
    }

    fileprivate func connected(_ connected: CBPeripheral) {
        guard connected.identifier == peripheral?.identifier else { return }
        log.info("Heart rate monitor linked; looking for heart rate")
        subscribe(connected)
    }

    fileprivate func disconnected(_ lost: CBPeripheral, error: Error?) {
        guard lost.identifier == peripheral?.identifier else { return }
        bpm = nil
        if users > 0, lost.identifier == pairedID {
            if let error { log.info("Heart rate monitor dropped: \(error.localizedDescription)") }
            connectIfPaired() // waits until it's back in range, under either identifier
        } else if status != .bluetoothOff {
            status = isPaired ? .idle : .notPaired
        }
    }

    fileprivate func discoveredServices(_ on: CBPeripheral, error: Error?) {
        guard on.identifier == peripheral?.identifier else { return }
        guard let service = on.services?.first(where: { $0.uuid == Self.heartRateService }) else {
            log.error("Heart rate monitor has no heart rate service: \(error?.localizedDescription ?? "not broadcasting", privacy: .public)")
            status = .noHeartRate
            return
        }
        on.discoverCharacteristics([Self.measurementCharacteristic], for: service)
    }

    fileprivate func discoveredCharacteristics(_ on: CBPeripheral, service: CBService, error: Error?) {
        guard on.identifier == peripheral?.identifier else { return }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.measurementCharacteristic }) else {
            log.error("Heart rate monitor has no heart rate measurement: \(error?.localizedDescription ?? "missing", privacy: .public)")
            status = .noHeartRate
            return
        }
        on.setNotifyValue(true, for: characteristic)
    }

    fileprivate func notifyingChanged(_ on: CBPeripheral, isNotifying: Bool, error: Error?) {
        guard on.identifier == peripheral?.identifier else { return }
        if isNotifying {
            log.info("Heart rate monitor subscribed: \(on.identifier.uuidString.prefix(8), privacy: .public)")
            status = .connected // keeps scanning until a reading arrives, in case this link stays silent
        } else {
            log.error("Heart rate monitor wouldn't send heart rate: \(error?.localizedDescription ?? "unsubscribed", privacy: .public)")
            status = .noHeartRate
        }
    }

    /// A Garmin adds its heart rate service when Broadcast Heart Rate is turned
    /// on, while staying linked; iOS reports that as changed services.
    fileprivate func servicesChanged(_ on: CBPeripheral) {
        guard on.identifier == peripheral?.identifier, on.state == .connected else { return }
        log.info("Heart rate monitor's services changed; looking for heart rate again")
        if status != .connected { status = .connecting }
        on.discoverServices([Self.heartRateService])
    }

    fileprivate func received(_ value: Data?) {
        guard let value else { return }
        guard let bpm = Self.bpm(fromMeasurement: value) else {
            log.info("Heart rate reading skipped: \(value.map { String(format: "%02x", $0) }.joined(), privacy: .public)")
            skippingReadings = true
            return
        }
        skippingReadings = false
        if status != .connected { status = .connected }
        if !isSearching, central?.isScanning == true {
            log.info("Heart rate monitor sending heart rate")
            central?.stopScan()
        }
        record(bpm)
    }

    /// Beats per minute from a Heart Rate Measurement value (Bluetooth
    /// characteristic 0x2A37), or nil when the monitor says it isn't touching
    /// skin or the value isn't believable.
    nonisolated static func bpm(fromMeasurement data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        let contactSupported = flags & 0b100 != 0
        let contactDetected = flags & 0b010 != 0
        if contactSupported && !contactDetected { return nil }
        let value: Int
        if flags & 0b001 == 0 {
            guard bytes.count >= 2 else { return nil }
            value = Int(bytes[1])
        } else {
            guard bytes.count >= 3 else { return nil }
            value = Int(bytes[1]) | Int(bytes[2]) << 8
        }
        return (25...250).contains(value) ? value : nil
    }
}

/// Receives CoreBluetooth's callbacks (on the main queue) and hands them to the monitor.
private final class BluetoothDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var monitor: HeartRateMonitor?

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { monitor?.stateChanged(central.state) }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        MainActor.assumeIsolated { monitor?.didDiscover(peripheral, advertisedName: name) }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { monitor?.connected(peripheral) }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { monitor?.disconnected(peripheral, error: error) }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { monitor?.disconnected(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated { monitor?.discoveredServices(peripheral, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { monitor?.discoveredCharacteristics(peripheral, service: service, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let isNotifying = characteristic.isNotifying
        MainActor.assumeIsolated { monitor?.notifyingChanged(peripheral, isNotifying: isNotifying, error: error) }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        MainActor.assumeIsolated { monitor?.servicesChanged(peripheral) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        MainActor.assumeIsolated { monitor?.received(value) }
    }
}
