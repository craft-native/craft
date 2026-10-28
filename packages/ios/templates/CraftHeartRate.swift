#if CRAFT_PERMISSION_BLUETOOTH
import CoreBluetooth
#endif
import Foundation
import UIKit

/// A heart-rate call that did not happen: the message a page sees, and the
/// bridge's error code.
struct CraftHeartRateError: Error {
    let message: String
    var code: String = "CRAFT_ERROR"
}

/// One Heart Rate Measurement (characteristic 0x2A37 of the Bluetooth SIG's
/// Heart Rate Service, 0x180D), decoded.
///
/// The payload is a flags byte and then the fields the flags announce, all
/// little-endian:
///
///   bit 0     the heart rate is a uint16 (else a uint8)
///   bits 1-2  sensor contact: bit 2 says the strap reports it at all,
///             bit 1 that the skin is touching (a strap worn loose reads 0)
///   bit 3     a uint16 of energy expended, kilojoules, follows the rate
///   bit 4     uint16 RR intervals follow, as many as fit, in 1/1024 s
///
/// Every strap and every watch that broadcasts its heart rate (Polar, Garmin,
/// Wahoo, an Apple Watch with a broadcasting app) sends this one shape.
struct CraftHeartRateMeasurement: Equatable {
    /// Beats per minute.
    let bpm: Int
    /// Whether the strap is touching skin; nil when it cannot tell.
    let sensorContact: Bool?
    /// Kilojoules since the strap was last reset; nil when it does not count them.
    let energyExpended: Int?
    /// The time between beats, in milliseconds, oldest first.
    let rrIntervals: [Double]

    /// Nil for a payload too short for what its flags announce.
    static func parse(_ bytes: [UInt8]) -> CraftHeartRateMeasurement? {
        guard let flags = bytes.first else { return nil }
        var offset = 1
        func uint8() -> Int? {
            guard offset < bytes.count else { return nil }
            defer { offset += 1 }
            return Int(bytes[offset])
        }
        func uint16() -> Int? {
            guard offset + 1 < bytes.count else { return nil }
            defer { offset += 2 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        guard let bpm = flags & 0x01 != 0 ? uint16() : uint8() else { return nil }
        let contact: Bool? = flags & 0x04 != 0 ? flags & 0x02 != 0 : nil
        var energy: Int?
        if flags & 0x08 != 0 {
            guard let value = uint16() else { return nil }
            energy = value
        }
        var intervals: [Double] = []
        if flags & 0x10 != 0 {
            while let value = uint16() { intervals.append(Double(value) * 1000 / 1024) }
        }
        return CraftHeartRateMeasurement(bpm: bpm, sensorContact: contact, energyExpended: energy, rrIntervals: intervals)
    }

    static func parse(_ data: Data) -> CraftHeartRateMeasurement? { parse([UInt8](data)) }

    /// The payload a strap would send for these values: the simulator's
    /// stand-in speaks it, so its readings take the same path as a strap's.
    static func encode(bpm: Int, sensorContact: Bool? = true, energyExpended: Int? = nil, rrIntervals: [Double] = []) -> [UInt8] {
        var flags: UInt8 = 0
        var body: [UInt8] = []
        func append16(_ value: Int) { body.append(UInt8(value & 0xFF)); body.append(UInt8((value >> 8) & 0xFF)) }
        if bpm > 255 {
            flags |= 0x01
            append16(bpm)
        } else {
            body.append(UInt8(max(0, bpm)))
        }
        if let contact = sensorContact { flags |= 0x04 | (contact ? 0x02 : 0) }
        if let energy = energyExpended {
            flags |= 0x08
            append16(energy)
        }
        if !rrIntervals.isEmpty {
            flags |= 0x10
            for interval in rrIntervals { append16(Int((interval * 1024 / 1000).rounded())) }
        }
        return [flags] + body
    }
}

/// A heart-rate strap, or a watch broadcasting its heart rate, read during a
/// workout: the page's `craft.heartRate` (CraftApp.swift) and a native
/// screen's `HeartRate` module (CraftNativeActions.swift), one service for
/// both.
///
/// CoreBluetooth central for the standard Heart Rate Service (0x180D):
/// - `scan` finds what advertises the service nearby (and a strap the phone
///   is already connected to, which does not advertise), each one a
///   `{type: 'device'}` event with its name and signal strength.
/// - `connect` subscribes to Heart Rate Measurement (0x2A37); every reading
///   is a `{type: 'reading'}` event with bpm and, when the strap sends them,
///   RR intervals. The device is remembered, and `reconnect` finds it again
///   next time without a scan.
/// - A strap that drops out (out of range, the battery, a sweaty contact) is
///   asked for again until `disconnect`: CoreBluetooth's pending connect
///   never times out, so it comes back by itself when the strap does.
/// - `startRecording` keeps every reading on disk until `stopRecording`, as
///   the location recording keeps fixes: the readings survive the web view
///   being suspended with the screen locked (the `bluetooth-central`
///   background mode keeps them coming) and the app being closed.
///
/// Connection changes are `{type: 'state'}` events. All of them reach the
/// page as `craftHeartRate` and every native screen the same way.
///
/// Simulator builds have no Bluetooth; with the `CraftFakeHeartRateMonitor`
/// default set (`xcrun simctl spawn booted defaults write <bundle id>
/// CraftFakeHeartRateMonitor -bool YES`) a made-up strap stands in, whose
/// readings are encoded as 0x2A37 payloads and decoded like a real one's. Its
/// RR intervals vary beat to beat with the breath, as a heart's do.
///
/// Everything runs on main: the central manager delivers there, and every
/// caller hops there first.
#if CRAFT_PERMISSION_BLUETOOTH
final class CraftHeartRate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    typealias Completion = (Result<Any, CraftHeartRateError>) -> Void

    static let shared = CraftHeartRate()

    static let serviceUUID = CBUUID(string: "180D")
    static let measurementUUID = CBUUID(string: "2A37")
    /// How long `connect` waits before answering TIMEOUT. The connection is
    /// still asked for after that: a strap only wakes when it is worn.
    static let connectTimeout: TimeInterval = 15
    /// A reading older than this is no longer "now".
    static let staleAfter: TimeInterval = 10
    /// Seven days at one reading a second, including multi-day ultra events.
    static let maxRecordedSamples = 604_800

    private let clock: () -> Date
    private let recordingDirectory: URL?

    init(now: @escaping () -> Date = Date.init, recordingDirectory: URL? = nil, archiveWriter: @escaping CraftRecordingArchive.Writer = CraftRecordingArchive.writeAtomically) {
        self.clock = now
        self.recordingDirectory = recordingDirectory
        self.archiveWriter = archiveWriter
        super.init()
    }

    /// The web view's coordinator, which sends an event to the page and every
    /// native screen. False (or unset, in an app without a web view) and the
    /// event goes to the native screens alone.
    var pageSink: (([String: Any]) -> Bool)?

    private var central: CBCentralManager?
    private var stateWaiters: [() -> Void] = []
    private var discovered: [UUID: (peripheral: CBPeripheral?, name: String, rssi: Int)] = [:]
    private var scanning = false
    private var scanStop: DispatchWorkItem?
    private var peripheral: CBPeripheral?
    private var deviceId: UUID?
    private var deviceName: String?
    private var connection = "disconnected"
    /// Between connect and disconnect: a lost strap is asked for again.
    private var wantsConnection = false
    private var connectWaiters: [Completion] = []
    private var connectDeadline: DispatchWorkItem?
    private var latest: CraftHeartRateMeasurement?
    private var latestAt: Date?
    // Packet freshness is separate from a valid BPM: a monitor reporting no
    // skin contact is still delivering notifications and needs no reconnect.
    private var packetAt: Date?
    private var subscriptionAt: Date?
    private var recoveryTimer: Timer?
    private var hasSubscribed = false

    private var archiveWriter: CraftRecordingArchive.Writer = CraftRecordingArchive.writeAtomically
    private var recordingActive = false
    private var recordingId: String?
    private var recordingStartedAt: Double?
    private var recordingPaused = false
    private var recordedCount = 0
    private var restored = false

    private static let rememberedKey = "CraftHeartRate.lastDevice"

    // MARK: The simulator's stand-in

    /// A strap that is not there: one device, readings once a second.
    private var simulated: Bool = {
        #if targetEnvironment(simulator)
        return UserDefaults.standard.bool(forKey: "CraftFakeHeartRateMonitor")
        #else
        return false
        #endif
    }()
    private static let simulatedId = UUID(uuidString: "00000000-0000-4000-8000-00000000180D")!
    private var simulatedTimer: Timer?
    private var simulatedBeat = 0
    /// Milliseconds since the stand-in connected, and how far its beats reach.
    private var simulatedElapsed: Double = 0
    private var simulatedBeatsUntil: Double = 0

    // MARK: Entry

    /// One call from a page or a native screen, by method name.
    func perform(method: String, args: [Any], completion: @escaping Completion) {
        let options = args.first as? [String: Any] ?? [:]
        if method == "acknowledgeRecording" && !options.keys.contains("expectedId") {
            return completion(.failure(CraftHeartRateError(message: "Acknowledgement needs expectedId", code: "INVALID_ARGUMENT")))
        }
        DispatchQueue.main.async {
            do { try self.restoreRecording() }
            catch { return completion(.failure(CraftHeartRateError(message: error.localizedDescription, code: "RECORDING_STORAGE_ERROR"))) }
            if ["getRecordingState", "readRecording", "stopRecording", "acknowledgeRecording"].contains(method),
               options.keys.contains("expectedId") {
                guard let id = options["expectedId"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return completion(.failure(CraftHeartRateError(message: "expectedId must be a nonempty recording ID", code: "INVALID_ARGUMENT")))
                }
                do {
                    if method == "acknowledgeRecording" {
                        guard self.recordingId != id || !self.recordingActive else {
                            return completion(.failure(CraftHeartRateError(message: "The recording is still active", code: "RECORDING_ALREADY_ACTIVE")))
                        }
                        var known = try self.recordingId == id || CraftRecordingArchive.isAcknowledged(self.directory, "heart-rate", id)
                        if !known { known = try CraftRecordingArchive.read(self.directory, "heart-rate", id) != nil }
                        guard known else { return completion(.failure(CraftHeartRateError(message: "Unknown recording ID", code: "RECORDING_CONFLICT"))) }
                        try CraftRecordingArchive.acknowledge(self.directory, "heart-rate", id)
                        if self.recordingId == id {
                            if FileManager.default.fileExists(atPath: self.samplesURL.path) { try FileManager.default.removeItem(at: self.samplesURL) }
                            self.recordingId = nil
                            self.recordingStartedAt = nil
                            self.recordedCount = 0
                            try self.persistRecording()
                        }
                        return completion(.success(true))
                    }
                    if var archived = try CraftRecordingArchive.read(self.directory, "heart-rate", id) {
                        if method == "readRecording" {
                            let since = craftNativeNumber(options["since"]).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil }
                            let samples = archived["samples"] as? [[String: Any]] ?? []
                            return completion(.success(samples.filter { since == nil || (($0["timestamp"] as? NSNumber)?.doubleValue ?? 0) > since! }))
                        }
                        if method == "getRecordingState" { archived.removeValue(forKey: "samples") }
                        return completion(.success(archived))
                    }
                    if let error = self.recordingIdentityError(options) { return completion(.failure(error)) }
                } catch let error as CraftNativeActionError {
                    return completion(.failure(CraftHeartRateError(message: error.message, code: error.code)))
                } catch { return completion(.failure(CraftHeartRateError(message: "Unable to persist the recording", code: "RECORDING_STORAGE_ERROR"))) }
            }
            if ["pauseRecording", "resumeRecording", "stopRecording", "readRecording"].contains(method),
               let error = self.recordingIdentityError(options) {
                return completion(.failure(error))
            }
            switch method {
            case "getState":
                self.recoverQuietBroadcast()
                completion(.success(self.state()))
            case "requestAuthorization": self.requestAuthorization(completion: completion)
            case "scan": self.scan(seconds: craftNativeNumber(options["timeout"]).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil }, completion: completion)
            case "stopScan":
                self.stopScan()
                completion(.success(self.state()))
            case "getDevices": completion(.success(self.devices()))
            case "connect": self.connect(id: options["id"] as? String, wait: true, completion: completion)
            case "reconnect": self.connect(id: nil, wait: false, completion: completion)
            case "disconnect": self.disconnect(forget: options["forget"] as? Bool ?? false, completion: completion)
            case "startRecording": self.startRecording(options: options, completion: completion)
            case "pauseRecording": self.setRecordingPaused(true, completion: completion)
            case "resumeRecording": self.setRecordingPaused(false, completion: completion)
            case "stopRecording": self.stopRecording(completion: completion)
            case "getRecordingState": completion(.success(self.recordingSummary(count: true)))
            case "readRecording":
                do {
                    let since = craftNativeNumber(options["since"]).map { $0.doubleValue }.flatMap { $0.isFinite ? $0 : nil }
                    completion(.success(try self.persistedSamples(since: since)))
                }
                catch { completion(.failure(CraftHeartRateError(message: "Unable to read the recording", code: "RECORDING_STORAGE_ERROR"))) }
            default: completion(.failure(CraftHeartRateError(message: "Unsupported HeartRate method", code: "UNKNOWN_ACTION")))
            }
        }
    }

    // MARK: State

    static func authorizationName(_ value: CBManagerAuthorization) -> String {
        switch value {
        case .allowedAlways: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "denied"
        }
    }

    static func bluetoothName(_ value: CBManagerState) -> String {
        switch value {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .resetting: return "resetting"
        case .unknown: return "unknown"
        @unknown default: return "unknown"
        }
    }

    private var authorization: String { simulated ? "authorized" : Self.authorizationName(CBManager.authorization) }

    /// "unknown" until something has asked for Bluetooth: reading it would
    /// make the central manager, and that is what shows iOS's prompt.
    private var bluetooth: String {
        if simulated { return "poweredOn" }
        guard let central else { return "unknown" }
        return Self.bluetoothName(central.state)
    }

    private func remembered() -> [String: Any]? {
        guard let device = UserDefaults.standard.dictionary(forKey: Self.rememberedKey),
              device["id"] is String else { return nil }
        return device
    }

    private func remember(id: UUID, name: String) {
        UserDefaults.standard.set(["id": id.uuidString, "name": name], forKey: Self.rememberedKey)
    }

    func state() -> [String: Any] {
        let fresh = latestAt.map { clock().timeIntervalSince($0) <= Self.staleAfter } ?? false
        let device: Any = deviceId.map { ["id": $0.uuidString, "name": deviceName ?? "Heart rate monitor"] as [String: Any] } ?? NSNull()
        return [
            "available": bluetooth != "unsupported",
            "bluetooth": bluetooth,
            "authorization": authorization,
            "scanning": scanning,
            "connection": connection,
            "device": device,
            "lastDevice": remembered() ?? NSNull(),
            "bpm": (fresh ? latest?.bpm : nil) ?? NSNull(),
            "lastReadingAt": latestAt.map { $0.timeIntervalSince1970 * 1000 } ?? NSNull(),
            "recording": recordingSummary(count: false),
        ]
    }

    private func emit(_ detail: [String: Any]) {
        if pageSink?(detail) != true { CraftWebServices.forward("craftHeartRate", data: detail) }
    }

    private func emitState() {
        var detail = state()
        detail["type"] = "state"
        emit(detail)
    }

    // MARK: Bluetooth

    /// The central manager, made on first use: that is when iOS asks.
    private func whenReady(_ run: @escaping () -> Void) {
        if simulated { return run() }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        if central!.state == .unknown || central!.state == .resetting {
            stateWaiters.append(run)
        } else {
            run()
        }
    }

    /// A reason the radio cannot be used now, or nil when it can.
    private func unusable() -> CraftHeartRateError? {
        switch bluetooth {
        case "poweredOn": return nil
        case "poweredOff": return CraftHeartRateError(message: "Bluetooth is off", code: "BLUETOOTH_OFF")
        case "unauthorized": return CraftHeartRateError(message: "Bluetooth access was not allowed", code: "NOT_AUTHORIZED")
        case "unsupported": return CraftHeartRateError(message: "This device has no Bluetooth", code: "UNSUPPORTED")
        default: return CraftHeartRateError(message: "Bluetooth is not ready", code: "BLUETOOTH_UNAVAILABLE")
        }
    }

    private func requestAuthorization(completion: @escaping Completion) {
        whenReady { completion(.success(self.authorization)) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let waiting = stateWaiters
        if central.state != .unknown && central.state != .resetting {
            stateWaiters.removeAll()
            waiting.forEach { $0() }
        }
        if central.state == .poweredOn {
            // Bluetooth back on (or on at last): ask for the strap again.
            if wantsConnection, let peripheral, peripheral.state == .disconnected {
                connection = "reconnecting"
                central.connect(peripheral)
            }
        } else if central.state != .unknown {
            scanning = false
            if wantsConnection && connection != "disconnected" { connection = "reconnecting" }
        }
        emitState()
    }

    // MARK: Scanning

    private func devices() -> [[String: Any]] {
        discovered
            .map { id, device in ["id": id.uuidString, "name": device.name, "rssi": device.rssi] as [String: Any] }
            .sorted { ($0["rssi"] as? Int ?? -200) > ($1["rssi"] as? Int ?? -200) }
    }

    private func found(id: UUID, peripheral: CBPeripheral?, name: String, rssi: Int) {
        let known = discovered[id] != nil
        discovered[id] = (peripheral, name, rssi)
        if !known { emit(["type": "device", "device": ["id": id.uuidString, "name": name, "rssi": rssi]]) }
    }

    private func scan(seconds: Double?, completion: @escaping Completion) {
        whenReady {
            if let reason = self.unusable() { return completion(.failure(reason)) }
            self.discovered.removeAll()
            self.scanning = true
            if self.simulated {
                self.found(id: Self.simulatedId, peripheral: nil, name: "Simulated HRM", rssi: -48)
            } else if let central = self.central {
                // A strap already connected to this phone (by Settings or
                // another app) no longer advertises; it is still a choice.
                for peripheral in central.retrieveConnectedPeripherals(withServices: [Self.serviceUUID]) {
                    self.found(id: peripheral.identifier, peripheral: peripheral, name: peripheral.name ?? "Heart rate monitor", rssi: 0)
                }
                central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
            self.scanStop?.cancel()
            let stop = DispatchWorkItem { [weak self] in self?.stopScan() }
            self.scanStop = stop
            DispatchQueue.main.asyncAfter(deadline: .now() + min(max(seconds ?? 15, 1), 60), execute: stop)
            self.emitState()
            completion(.success(self.state()))
        }
    }

    private func stopScan() {
        scanStop?.cancel()
        scanStop = nil
        guard scanning else { return }
        scanning = false
        if central?.state == .poweredOn { central?.stopScan() }
        emitState()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "Heart rate monitor"
        // 127 is CoreBluetooth's "no reading".
        found(id: peripheral.identifier, peripheral: peripheral, name: name, rssi: RSSI.intValue == 127 ? -100 : RSSI.intValue)
    }

    // MARK: Connecting

    private func connect(id: String?, wait: Bool, completion: @escaping Completion) {
        let target = id ?? remembered()?["id"] as? String
        guard let target, let uuid = UUID(uuidString: target) else {
            if wait { return completion(.failure(CraftHeartRateError(message: "connect needs the id of a device from scan", code: "INVALID_ARGUMENT"))) }
            return completion(.success(state()))
        }
        whenReady {
            if let reason = self.unusable() { return completion(.failure(reason)) }
            // A connected link can lose its notification subscription when a
            // broadcasting watch restarts. Keep healthy links, repair quiet ones.
            if self.deviceId == uuid && self.wantsConnection {
                self.recoverQuietBroadcast()
                if self.connection == "connected" || !wait { return completion(.success(self.state())) }
                self.connectWaiters.append(completion)
                self.armConnectDeadline()
                return
            }
            self.release()
            let saved = self.remembered()
            let savedName = (saved?["id"] as? String) == target ? saved?["name"] as? String : nil
            let name = self.discovered[uuid]?.name ?? savedName ?? "Heart rate monitor"
            if self.simulated {
                guard uuid == Self.simulatedId else { return completion(.failure(CraftHeartRateError(message: "No heart-rate monitor with that id is nearby", code: "NOT_FOUND"))) }
            } else {
                let peripheral = self.discovered[uuid]?.peripheral ?? self.central?.retrievePeripherals(withIdentifiers: [uuid]).first
                guard let peripheral else { return completion(.failure(CraftHeartRateError(message: "No heart-rate monitor with that id is nearby", code: "NOT_FOUND"))) }
                peripheral.delegate = self
                self.peripheral = peripheral
            }
            self.deviceId = uuid
            self.deviceName = name
            self.wantsConnection = true
            self.connection = "connecting"
            self.subscriptionAt = self.clock()
            self.startRecoveryWatch()
            self.remember(id: uuid, name: name)
            if wait {
                self.connectWaiters.append(completion)
                self.armConnectDeadline()
            }
            if self.simulated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.simulatedConnected() }
            } else if let peripheral = self.peripheral {
                self.central?.connect(peripheral)
            }
            self.emitState()
            if !wait { completion(.success(self.state())) }
        }
    }

    /// `connect` answers TIMEOUT after a while; the strap is still asked
    /// for, since it may wake up once it is worn.
    private func armConnectDeadline() {
        guard connectDeadline == nil else { return }
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.connection != "connected" else { return }
            self.settleConnect(.failure(CraftHeartRateError(message: "The heart-rate monitor did not answer. Wear it to wake it up.", code: "TIMEOUT")))
        }
        connectDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: deadline)
    }

    private func settleConnect(_ result: Result<Any, CraftHeartRateError>) {
        connectDeadline?.cancel()
        connectDeadline = nil
        let waiting = connectWaiters
        connectWaiters.removeAll()
        waiting.forEach { $0(result) }
    }

    /// Lets go of the current strap without telling anyone.
    private func release() {
        wantsConnection = false
        hasSubscribed = false
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        packetAt = nil
        subscriptionAt = nil
        simulatedTimer?.invalidate()
        simulatedTimer = nil
        if let peripheral, let central, peripheral.state != .disconnected { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        deviceId = nil
        deviceName = nil
        latest = nil
        latestAt = nil
        connection = "disconnected"
        settleConnect(.failure(CraftHeartRateError(message: "Another heart-rate monitor was chosen", code: "CANCELLED")))
    }

    private func disconnect(forget: Bool, completion: @escaping Completion) {
        release()
        if forget { UserDefaults.standard.removeObject(forKey: Self.rememberedKey) }
        emitState()
        completion(.success(state()))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral.identifier == deviceId, wantsConnection else { return }
        packetAt = nil
        subscriptionAt = clock()
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == deviceId, wantsConnection else { return }
        // Asked for again: a failed attempt is usually a strap going to sleep.
        connection = "reconnecting"
        central.connect(peripheral)
        emitState()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral.identifier == deviceId else { return }
        latest = nil
        latestAt = nil
        packetAt = nil
        subscriptionAt = clock()
        if wantsConnection {
            connection = "reconnecting"
            central.connect(peripheral)
        } else {
            connection = "disconnected"
        }
        emitState()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == deviceId, wantsConnection else { return }
        if error != nil { return restartBroadcast() }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
            if hasSubscribed { return restartBroadcast() }
            notAHeartRateMonitor(peripheral)
            return
        }
        peripheral.discoverCharacteristics([Self.measurementUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral.identifier == deviceId, wantsConnection, service.uuid == Self.serviceUUID else { return }
        if error != nil { return restartBroadcast() }
        guard let measurement = service.characteristics?.first(where: { $0.uuid == Self.measurementUUID }) else {
            if hasSubscribed { return restartBroadcast() }
            notAHeartRateMonitor(peripheral)
            return
        }
        peripheral.setNotifyValue(true, for: measurement)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.measurementUUID, peripheral.identifier == deviceId, wantsConnection else { return }
        if characteristic.isNotifying && error == nil {
            hasSubscribed = true
            subscriptionAt = clock()
            connection = "connected"
            emitState()
            settleConnect(.success(state()))
        } else {
            restartBroadcast()
        }
    }

    // Garmin may invalidate its service when HR broadcast is toggled without
    // dropping the physical link. Discover and subscribe to the replacement.
    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        guard peripheral.identifier == deviceId, wantsConnection,
              invalidatedServices.contains(where: { $0.uuid == Self.serviceUUID }) else { return }
        connection = "reconnecting"
        latest = nil
        latestAt = nil
        packetAt = nil
        subscriptionAt = clock()
        peripheral.discoverServices([Self.serviceUUID])
        emitState()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.measurementUUID, peripheral.identifier == deviceId, wantsConnection else { return }
        if error != nil { return restartBroadcast() }
        guard let value = characteristic.value else { return }
        received([UInt8](value))
    }

    private func notAHeartRateMonitor(_ peripheral: CBPeripheral) {
        wantsConnection = false
        hasSubscribed = false
        recoveryTimer?.invalidate()
        recoveryTimer = nil
        central?.cancelPeripheralConnection(peripheral)
        connection = "disconnected"
        settleConnect(.failure(CraftHeartRateError(message: "That device does not send a heart rate", code: "NOT_HEART_RATE_MONITOR")))
        emitState()
    }

    /// Run independently of any player or big-timer screen. A pending radio
    /// connection stays pending until the watch returns; only a connected link
    /// with a silent subscription is restarted.
    private func startRecoveryWatch() {
        recoveryTimer?.invalidate()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.recoverQuietBroadcast()
        }
    }

    private func recoverQuietBroadcast() {
        guard wantsConnection, let since = packetAt ?? subscriptionAt else { return }
        let quiet = clock().timeIntervalSince(since)
        if connection == "connected" && quiet > 20 {
            restartBroadcast()
        } else if connection != "connected", peripheral?.state == .connected, quiet > 30 {
            restartBroadcast()
        }
    }

    /// Keep the recording and device choice while replacing the subscription.
    /// CoreBluetooth's disconnect callback starts the next connection once the
    /// previous one has actually closed.
    private func restartBroadcast() {
        guard wantsConnection else { return }
        connection = "reconnecting"
        latest = nil
        latestAt = nil
        packetAt = nil
        subscriptionAt = clock()
        emitState()
        if simulated {
            simulatedTimer?.invalidate()
            simulatedTimer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.simulatedConnected() }
        } else if let peripheral, let central, central.state == .poweredOn {
            if peripheral.state == .disconnected { central.connect(peripheral) }
            else if peripheral.state != .disconnecting { central.cancelPeripheralConnection(peripheral) }
        }
    }

    // MARK: Readings

    private func received(_ bytes: [UInt8]) {
        // A strap reads 0 between losing the skin and giving up; that is no
        // heart rate, and neither is anything a heart could not do.
        packetAt = clock()
        guard let reading = CraftHeartRateMeasurement.parse(bytes), reading.sensorContact != false, reading.bpm >= 20, reading.bpm <= 250 else {
            latest = nil
            latestAt = nil
            emitState()
            return
        }
        let now = clock()
        latest = reading
        latestAt = now
        let timestamp = (now.timeIntervalSince1970 * 1000).rounded()
        let intervals = reading.rrIntervals.map { ($0 * 10).rounded() / 10 }
        var detail: [String: Any] = [
            "type": "reading",
            "bpm": reading.bpm,
            "rrIntervals": intervals,
            "contact": reading.sensorContact ?? NSNull(),
            "energyExpended": reading.energyExpended ?? NSNull(),
            "timestamp": timestamp,
        ]
        if let deviceId { detail["deviceId"] = deviceId.uuidString }
        appendSample(["timestamp": timestamp, "bpm": reading.bpm, "rr": intervals])
        emit(detail)
    }

    private func simulatedConnected() {
        guard simulated, wantsConnection, deviceId == Self.simulatedId else { return }
        connection = "connected"
        subscriptionAt = clock()
        emitState()
        settleConnect(.success(state()))
        simulatedTimer?.invalidate()
        simulatedElapsed = 0
        simulatedBeatsUntil = 0
        simulatedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.simulatedBeat += 1
            self.simulatedElapsed += 1000
            // A steady run with a slow swell, the way a real one drifts.
            let rate = 142 + sin(Double(self.simulatedBeat) / 20) * 12
            var beatsUntil = self.simulatedBeatsUntil
            let intervals = Self.simulatedIntervals(rate: rate, from: &beatsUntil, until: self.simulatedElapsed)
            self.simulatedBeatsUntil = beatsUntil
            guard !intervals.isEmpty else { return }
            // The rate a strap reports is the one its intervals give.
            let bpm = Int((60_000 / (intervals.reduce(0, +) / Double(intervals.count))).rounded())
            self.received(CraftHeartRateMeasurement.encode(bpm: bpm, sensorContact: true, rrIntervals: intervals))
        }
    }

    /// The beats from `start` (ms) until `end`, each interval in ms: the
    /// rate's own interval, plus respiratory sinus arrhythmia (beats come
    /// closer on the in-breath and spread on the out-breath over a ten-second
    /// breath, ±4% of the interval: ±40 ms at 60 bpm) and a few ms of noise,
    /// so a heart-rate variability worked out from them means something.
    /// `start` moves to the last beat.
    static func simulatedIntervals(rate: Double, from start: inout Double, until end: Double, noise: () -> Double = { Double.random(in: -4...4) }) -> [Double] {
        let base = 60_000 / rate
        var intervals: [Double] = []
        while start < end {
            let breath = sin(2 * Double.pi * start / 10_000)
            let interval = base * (1 - 0.04 * breath) + noise()
            start += interval
            intervals.append(interval)
        }
        return intervals
    }

    // MARK: Recording

    private var directory: URL {
        recordingDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private var stateURL: URL { directory.appendingPathComponent("craft-heart-rate-recording-state.json") }
    private var samplesURL: URL { directory.appendingPathComponent("craft-heart-rate-recording.jsonl") }

    /// A recording that was running when the app last closed carries on.
    private func restoreRecording() throws {
        guard !restored else { return }
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            if FileManager.default.fileExists(atPath: samplesURL.path), !(try Data(contentsOf: samplesURL)).isEmpty {
                throw CraftNativeActionError(code: "RECORDING_STORAGE_ERROR", message: "Recording metadata is missing")
            }
            restored = true
            return
        }
        let data = try Data(contentsOf: stateURL)
        guard let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let active = saved["active"] as? Bool else {
            throw CraftNativeActionError(code: "RECORDING_STORAGE_ERROR", message: "Invalid recording metadata")
        }
        recordingActive = active
        recordingId = saved["id"] as? String
        recordingStartedAt = saved["startedAt"] as? Double
        recordingPaused = saved["paused"] as? Bool ?? false
        if let id = recordingId, try CraftRecordingArchive.isAcknowledged(directory, "heart-rate", id) {
            try CraftRecordingArchive.acknowledge(directory, "heart-rate", id)
            if FileManager.default.fileExists(atPath: samplesURL.path) { try FileManager.default.removeItem(at: samplesURL) }
            recordingId = nil
            recordingStartedAt = nil
            recordingActive = false
            recordingPaused = false
            try persistRecording()
        }
        recordedCount = try persistedSamples(since: nil).count
        restored = true
    }

    private func persistRecording() throws {
        let saved: [String: Any] = ["active": recordingActive, "paused": recordingPaused, "id": recordingId ?? NSNull(), "startedAt": recordingStartedAt ?? NSNull()]
        try CraftRecordingArchive.writeAtomically(JSONSerialization.data(withJSONObject: saved), stateURL)
    }

    private func protect(_ url: URL) {
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try? protectedURL.setResourceValues(values)
    }

    private func recordingSummary(count: Bool) -> [String: Any] {
        var summary: [String: Any] = [
            "id": recordingId ?? NSNull(),
            "active": recordingActive,
            "paused": recordingPaused,
            "startedAt": recordingStartedAt ?? NSNull(),
        ]
        if count { summary["sampleCount"] = recordedCount }
        return summary
    }

    private func startRecording(options: [String: Any], completion: @escaping Completion) {
        guard !recordingActive else {
            return completion(.failure(CraftHeartRateError(message: "A heart-rate recording is already active", code: "RECORDING_ALREADY_ACTIVE")))
        }
        let id: String
        do {
            id = try CraftRecordingArchive.startId(options, directory: directory, kind: "heart-rate", currentId: recordingId)
            try CraftRecordingArchive.save(directory, "heart-rate", recordingSummary(count: true), samples: try persistedSamples(since: nil), writer: archiveWriter)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data().write(to: samplesURL, options: .atomic)
            protect(samplesURL)
        } catch let error as CraftNativeActionError {
            return completion(.failure(CraftHeartRateError(message: error.message, code: error.code)))
        } catch {
            return completion(.failure(CraftHeartRateError(message: "Unable to create the heart-rate recording", code: "RECORDING_STORAGE_ERROR")))
        }
        let previous = (recordingActive, recordingId, recordingStartedAt, recordingPaused, recordedCount)
        recordingActive = true
        recordingId = id
        recordingStartedAt = (clock().timeIntervalSince1970 * 1000).rounded()
        recordingPaused = false
        recordedCount = 0
        do { try persistRecording() }
        catch {
            (recordingActive, recordingId, recordingStartedAt, recordingPaused, recordedCount) = previous
            return completion(.failure(CraftHeartRateError(message: "Unable to persist the recording", code: "RECORDING_STORAGE_ERROR")))
        }
        completion(.success(recordingSummary(count: true)))
    }

    /// Runs on the same main-queue turn as the read or mutation it guards.
    private func recordingIdentityError(_ options: [String: Any]) -> CraftHeartRateError? {
        guard options.keys.contains("expectedId") else { return nil }
        guard let expected = options["expectedId"] as? String,
              !expected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return CraftHeartRateError(message: "expectedId must be a nonempty recording ID", code: "INVALID_ARGUMENT")
        }
        guard recordingId == expected else {
            return CraftHeartRateError(message: "The active heart-rate recording has changed", code: "RECORDING_CONFLICT")
        }
        return nil
    }

    private func setRecordingPaused(_ paused: Bool, completion: @escaping Completion) {
        guard recordingActive else {
            return completion(.failure(CraftHeartRateError(message: "No active heart-rate recording", code: "NO_ACTIVE_RECORDING")))
        }
        let previous = recordingPaused
        recordingPaused = paused
        do { try persistRecording() }
        catch {
            recordingPaused = previous
            return completion(.failure(CraftHeartRateError(message: "Unable to persist the recording", code: "RECORDING_STORAGE_ERROR")))
        }
        completion(.success(recordingSummary(count: true)))
    }

    private func stopRecording(completion: @escaping Completion) {
        do {
            let samples = try persistedSamples(since: nil)
            let wasActive = recordingActive
            let wasPaused = recordingPaused
            recordingActive = false
            recordingPaused = false
            do { try persistRecording() }
            catch { recordingActive = wasActive; recordingPaused = wasPaused; throw error }
            var summary = recordingSummary(count: true)
            summary["samples"] = samples
            completion(.success(summary))
        } catch { completion(.failure(CraftHeartRateError(message: "Unable to persist the recording", code: "RECORDING_STORAGE_ERROR"))) }
    }

    private func appendSample(_ sample: [String: Any]) {
        guard recordingActive, !recordingPaused, recordedCount < Self.maxRecordedSamples,
              let json = try? JSONSerialization.data(withJSONObject: sample) else { return }
        var line = json
        line.append(0x0A)
        do {
            let handle = try FileHandle(forWritingTo: samplesURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.close()
            recordedCount += 1
        } catch {
            print("Unable to append a heart-rate sample: \(error)")
        }
    }

    /// The recording's samples, oldest first; only those after `since` (ms) when given.
    private func loadSamples(since: Double?) -> [[String: Any]] { (try? persistedSamples(since: since)) ?? [] }

    private func persistedSamples(since: Double?) throws -> [[String: Any]] {
        if recordingId == nil { return [] }
        let text = try String(contentsOf: samplesURL, encoding: .utf8)
        return text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let sample = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let since, ((sample["timestamp"] as? NSNumber)?.doubleValue ?? 0) <= since { return nil }
            return sample
        }
    }
}
#else
final class CraftHeartRate {
    typealias Completion = (Result<Any, CraftHeartRateError>) -> Void
    static let shared = CraftHeartRate()
    var pageSink: (([String: Any]) -> Bool)?
    func perform(method: String, args: [Any], completion: @escaping Completion) {
        completion(.failure(CraftHeartRateError(message: "Bluetooth was not enabled when this app was built", code: "CAPABILITY_DISABLED")))
    }
}
#endif
