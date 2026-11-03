import Foundation
#if CRAFT_PERMISSION_MOTION
import CoreMotion
#endif

struct CraftPedometerSample {
    let startDate: Double
    let endDate: Double
    let steps: Int
    var distanceMeters: Double?
    var cadenceStepsPerSecond: Double?
    var paceSecondsPerMeter: Double?
    var averageActivePaceSecondsPerMeter: Double?
    var floorsAscended: Int?
    var floorsDescended: Int?

    var payload: [String: Any] {
        var value: [String: Any] = ["state": "sample", "kind": "interval", "startDate": startDate, "endDate": endDate, "steps": steps]
        if let distanceMeters { value["distanceMeters"] = distanceMeters }
        if let cadenceStepsPerSecond { value["cadenceStepsPerSecond"] = cadenceStepsPerSecond }
        if let paceSecondsPerMeter { value["paceSecondsPerMeter"] = paceSecondsPerMeter }
        if let averageActivePaceSecondsPerMeter { value["averageActivePaceSecondsPerMeter"] = averageActivePaceSecondsPerMeter }
        if let floorsAscended { value["floorsAscended"] = floorsAscended }
        if let floorsDescended { value["floorsDescended"] = floorsDescended }
        return value
    }
}

protocol CraftPedometerSource: AnyObject {
    var availability: [String: Bool] { get }
    var permission: String { get }
    func start(from: Date, receive: @escaping (Result<CraftPedometerSample, Error>) -> Void)
    func query(from: Date, to: Date, receive: @escaping (Result<CraftPedometerSample, Error>) -> Void)
    func stop()
}

#if CRAFT_PERMISSION_MOTION
private final class CraftCoreMotionPedometer: CraftPedometerSource {
    private let pedometer = CMPedometer()
    var availability: [String: Bool] {
        ["steps": CMPedometer.isStepCountingAvailable(), "distance": CMPedometer.isDistanceAvailable(),
         "floors": CMPedometer.isFloorCountingAvailable(), "cadence": CMPedometer.isCadenceAvailable(),
         "pace": CMPedometer.isPaceAvailable(), "history": CMPedometer.isStepCountingAvailable(), "background": false]
    }
    var permission: String {
        switch CMPedometer.authorizationStatus() {
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unavailable"
        }
    }
    private func handler(_ receive: @escaping (Result<CraftPedometerSample, Error>) -> Void) -> CMPedometerHandler {
        { data, error in
            let result: Result<CraftPedometerSample, Error>
            if let error { result = .failure(error) }
            else if let data {
                result = .success(CraftPedometerSample(startDate: data.startDate.timeIntervalSince1970 * 1000,
                    endDate: data.endDate.timeIntervalSince1970 * 1000, steps: data.numberOfSteps.intValue,
                    distanceMeters: data.distance?.doubleValue, cadenceStepsPerSecond: data.currentCadence?.doubleValue,
                    paceSecondsPerMeter: data.currentPace?.doubleValue, averageActivePaceSecondsPerMeter: data.averageActivePace?.doubleValue,
                    floorsAscended: data.floorsAscended?.intValue, floorsDescended: data.floorsDescended?.intValue))
            } else { result = .failure(NSError(domain: "CraftPedometer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Pedometer returned no data"])) }
            DispatchQueue.main.async { receive(result) }
        }
    }
    func start(from: Date, receive: @escaping (Result<CraftPedometerSample, Error>) -> Void) {
        pedometer.startUpdates(from: from, withHandler: handler(receive))
    }
    func query(from: Date, to: Date, receive: @escaping (Result<CraftPedometerSample, Error>) -> Void) {
        pedometer.queryPedometerData(from: from, to: to, withHandler: handler(receive))
    }
    func stop() { pedometer.stopUpdates() }
}
#endif

private final class CraftUnavailablePedometer: CraftPedometerSource {
    var availability: [String: Bool] { ["steps": false, "distance": false, "floors": false, "cadence": false, "pace": false, "history": false, "background": false] }
    var permission: String { "unavailable" }
    func start(from: Date, receive: @escaping (Result<CraftPedometerSample, Error>) -> Void) {}
    func query(from: Date, to: Date, receive: @escaping (Result<CraftPedometerSample, Error>) -> Void) {}
    func stop() {}
}

/// Interval counts are never relabelled as Android's counter since boot.
final class CraftNativePedometer {
    typealias Completion = (Result<Any, CraftNativeActionError>) -> Void
    private let makeSource: () -> CraftPedometerSource
    private let now: () -> Date
    private var live: CraftPedometerSource?
    private var pending = [String: CraftPedometerSource]()
    private var closed = false
    var emit: ([String: Any]) -> Void = { _ in }

    init(makeSource: (() -> CraftPedometerSource)? = nil, now: @escaping () -> Date = Date.init) {
        self.now = now
        self.makeSource = makeSource ?? {
            #if CRAFT_PERMISSION_MOTION
            return CraftCoreMotionPedometer()
            #else
            return CraftUnavailablePedometer()
            #endif
        }
    }

    func perform(method: String, args: [Any], token: String, completion: @escaping Completion) {
        guard !closed else { return completion(failure("HOST_CLOSED", "Pedometer host is closed")) }
        if method == "stop" { completion(.success(stop(reason: "requested"))); return }
        let source = makeSource()
        if method == "getAvailability" { completion(.success(source.availability)); return }
        if method == "getPermissionStatus" { completion(.success(source.permission)); return }
        guard ["start", "query", "requestPermission"].contains(method) else { return completion(failure("UNKNOWN_ACTION", "Unsupported Pedometer method")) }
        guard source.availability["steps"] == true else { return completion(failure("UNAVAILABLE", "Step counting is not present")) }
        if method == "requestPermission", ["granted", "denied", "restricted"].contains(source.permission) {
            completion(.success(source.permission)); return
        }
        guard !["denied", "restricted"].contains(source.permission) else { return completion(failure("PERMISSION_DENIED", "Motion access was denied or restricted")) }
        guard args.isEmpty || args.first is [String: Any] else { return completion(failure("INVALID_ARGUMENT", "Pedometer options must be an object")) }
        let options = args.first as? [String: Any] ?? [:]
        if let background = options["background"] {
            guard let flag = background as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return completion(failure("INVALID_ARGUMENT", "background must be boolean")) }
            if flag.boolValue { return completion(failure("UNSUPPORTED", "Background pedometer streaming is not supported")) }
        }
        let current = now().timeIntervalSince1970 * 1000
        let first: Double, last: Double
        if method == "requestPermission" { first = current - 1000; last = current }
        else {
            guard let start = date(options["startDate"] ?? (method == "start" ? current : NSNull())),
                  let end = date(options["endDate"] ?? current), start >= current - 7 * 86400 * 1000,
                  start <= current, end <= current, (method == "start" ? start <= end : start < end) else {
                return completion(failure("INVALID_ARGUMENT", "Dates must describe an interval within the last seven days"))
            }
            first = start; last = end
        }
        if method == "start" {
            let previous = live
            live = source
            source.start(from: Date(timeIntervalSince1970: first / 1000)) { [weak self, weak source] result in
                guard let self, let source, !self.closed, self.live === source else { return }
                switch result {
                case .success(let sample): self.emit(sample.payload)
                case .failure: self.stop(reason: ["denied", "restricted"].contains(source.permission) ? "permissionDenied" : "sensorError")
                }
            }
            previous?.stop()
            completion(.success(true))
        } else {
            pending[token] = source
            source.query(from: Date(timeIntervalSince1970: first / 1000), to: Date(timeIntervalSince1970: last / 1000)) { [weak self, weak source] result in
                guard let self, let source, !self.closed, self.pending[token] === source else { return }
                self.pending.removeValue(forKey: token)
                if method == "requestPermission", ["granted", "denied", "restricted"].contains(source.permission) {
                    completion(.success(source.permission)); return
                }
                switch result {
                case .success(let sample): completion(.success(method == "requestPermission" ? source.permission as Any : sample.payload))
                case .failure(let error): completion(self.failure(["denied", "restricted"].contains(source.permission) ? "PERMISSION_DENIED" : "SENSOR_ERROR", error.localizedDescription))
                }
            }
        }
    }

    private func date(_ value: Any) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }
    func cancel(_ token: String) { pending.removeValue(forKey: token) }
    @discardableResult func stop(reason: String) -> Bool {
        guard let previous = live else { return false }
        live = nil
        previous.stop()
        emit(["state": "stopped", "reason": reason])
        return true
    }
    func close() { closed = true; pending.removeAll(); stop(reason: "disposed"); emit = { _ in } }
    deinit { live?.stop() }
    private func failure(_ code: String, _ message: String) -> Result<Any, CraftNativeActionError> {
        .failure(CraftNativeActionError(code: code, message: message))
    }
}
