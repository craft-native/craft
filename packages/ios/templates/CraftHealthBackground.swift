import Foundation
#if CRAFT_PERMISSION_HEALTH
import HealthKit
#endif

struct CraftHealthBackgroundSample: Codable {
    let id: String
    let startDate: Double
    let endDate: Double
    var value: Double?
    var unit: String?
    var category: Int?
    var workoutActivity: UInt?
    var durationSeconds: Double?
}

struct CraftHealthBackgroundPage {
    let anchor: Data
    let samples: [CraftHealthBackgroundSample]
    let deleted: [String]
    let more: Bool
}

struct CraftHealthBackgroundBatch: Codable {
    let id: String
    let type: String
    let samples: [CraftHealthBackgroundSample]
    let deleted: [String]
}

struct CraftHealthBackgroundState: Codable {
    var anchors: [String: Data] = [:]
    var observedTypes: [String]? = nil
    var batches: [CraftHealthBackgroundBatch] = []
}

/// An atomic snapshot keeps a new anchor inseparable from its unconsumed delta.
protocol CraftHealthBackgroundPersistence {
    func load() throws -> CraftHealthBackgroundState
    func save(_ state: CraftHealthBackgroundState) throws
}

final class CraftHealthBackgroundFile: CraftHealthBackgroundPersistence {
    private let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> CraftHealthBackgroundState {
        guard FileManager.default.fileExists(atPath: url.path) else { return CraftHealthBackgroundState() }
        return try JSONDecoder().decode(CraftHealthBackgroundState.self, from: Data(contentsOf: url))
    }
    func save(_ state: CraftHealthBackgroundState) throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= 8 * 1024 * 1024 else { throw CraftHealthBackgroundError.outboxFull }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var excluded = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
    }
}

enum CraftHealthBackgroundError: Error { case unavailable, outboxFull, invalidAnchor, missingAnchor }

/// All callbacks and ownership transitions are serialized on the main queue.
protocol CraftHealthBackgroundSource {
    func observe(type: String, update: @escaping (Error?, @escaping () -> Void) -> Void) -> () -> Void
    func enable(type: String, frequency: String, completion: @escaping (Error?) -> Void)
    func disable(type: String)
    func read(type: String, anchor: Data?, completion: @escaping (Result<CraftHealthBackgroundPage, Error>) -> Void) -> () -> Void
}

final class CraftHealthBackground {
    static let shared: CraftHealthBackground = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        #if CRAFT_PERMISSION_HEALTH
        let source: CraftHealthBackgroundSource = CraftHealthKitBackgroundSource()
        #else
        let source: CraftHealthBackgroundSource = CraftUnavailableHealthBackgroundSource()
        #endif
        return CraftHealthBackground(source: source, persistence: CraftHealthBackgroundFile(url: base.appendingPathComponent("craft-health/delivery.json")))
    }()

    private final class Read {
        var completions: [() -> Void] = []
        var cancel: (() -> Void)?
        var deadline: DispatchWorkItem?
        var dirty = false
    }
    private let readTimeout: TimeInterval
    private let source: CraftHealthBackgroundSource
    private let persistence: CraftHealthBackgroundPersistence
    private var state = CraftHealthBackgroundState()
    private var loaded = false
    private var observers: [String: () -> Void] = [:]
    private var reads: [String: Read] = [:]
    private var types: [String] = []
    private var frequency = "hourly"
    private var generation = UUID()
    private(set) var errors: [String: String] = [:]
    var emit: (String) -> Void = { _ in }

    init(source: CraftHealthBackgroundSource, persistence: CraftHealthBackgroundPersistence, readTimeout: TimeInterval = 20) {
        self.source = source
        self.persistence = persistence
        self.readTimeout = readTimeout
    }

    func configure(types: [String], frequency: String) {
        stop()
        self.types = Array(Set(types)).sorted()
        self.frequency = frequency
        refresh()
    }

    func refresh() {
        if !loaded {
            do { state = try persistence.load(); loaded = true }
            catch { errors["storage"] = "Health delivery state could not be read"; return }
        }
        errors.removeValue(forKey: "storage")
        let current = generation
        let observed = Set(state.observedTypes ?? []).union(state.anchors.keys).union(types)
        if Set(state.observedTypes ?? []) != observed {
            do {
                var next = state
                next.observedTypes = observed.sorted()
                try persistence.save(next)
                state = next
            } catch { errors["storage"] = "Health registration intent could not be persisted"; return }
        }
        // Keep retired declarations so a temporarily unavailable store can
        // retry disabling them on a later launch, even before its first delta.
        for old in observed where !types.contains(old) { source.disable(type: old) }
        for type in types {
            if observers[type] == nil {
                observers[type] = source.observe(type: type) { [weak self] error, acknowledge in
                    guard let self, self.generation == current else { acknowledge(); return }
                    if error != nil { self.errors[type] = "HealthKit observer failed"; acknowledge(); return }
                    self.changed(type, acknowledge: acknowledge)
                }
            }
            source.enable(type: type, frequency: frequency) { [weak self] error in
                guard let self, self.generation == current else { return }
                if error != nil { self.errors["\(type).registration"] = "Background delivery registration failed" }
                else { self.errors.removeValue(forKey: "\(type).registration"); self.changed(type, acknowledge: {}) }
            }
        }
    }

    private func changed(_ type: String, acknowledge: @escaping () -> Void) {
        if let read = reads[type] { read.completions.append(acknowledge); read.dirty = true; return }
        let read = Read()
        read.completions.append(acknowledge)
        reads[type] = read
        // Never strand HealthKit's completion waiting for an unavailable store,
        // a locked device, an unresponsive query or JavaScript consumption.
        let deadline = DispatchWorkItem { [weak self, weak read] in
            guard let self, let read, self.reads[type] === read else { return }
            self.errors[type] = "HealthKit read timed out; anchor retained for retry"
            self.finish(type, read)
        }
        read.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + readTimeout, execute: deadline)
        next(type, read)
    }

    private func next(_ type: String, _ read: Read) {
        read.dirty = false
        read.cancel = source.read(type: type, anchor: state.anchors[type]) { [weak self, weak read] answer in
            guard let self, let read, self.reads[type] === read else { return }
            read.cancel = nil
            switch answer {
            case .failure:
                self.errors[type] = "HealthKit read failed; anchor retained for retry"
                self.finish(type, read)
            case .success(let page):
                do {
                    var next = self.state
                    if !page.samples.isEmpty || !page.deleted.isEmpty {
                        next.batches.append(CraftHealthBackgroundBatch(id: UUID().uuidString, type: type, samples: page.samples, deleted: page.deleted))
                    }
                    next.anchors[type] = page.anchor
                    try self.persistence.save(next)
                    self.state = next
                    self.errors.removeValue(forKey: type)
                    if !page.samples.isEmpty || !page.deleted.isEmpty { self.emit(type) }
                    if page.more || read.dirty { self.next(type, read) }
                    else { self.finish(type, read) }
                } catch {
                    self.errors[type] = "Health delivery could not be persisted; anchor retained for retry"
                    self.finish(type, read)
                }
            }
        }
    }

    private func finish(_ type: String, _ read: Read) {
        guard reads[type] === read else { return }
        reads.removeValue(forKey: type)
        read.deadline?.cancel()
        read.cancel?()
        let completions = read.completions
        read.completions.removeAll()
        completions.forEach { $0() }
    }

    func stop() {
        generation = UUID()
        observers.values.forEach { $0() }
        observers.removeAll()
        for (type, read) in reads { finish(type, read) }
    }

    func perform(method: String, args: [Any], completion: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        if !loaded { refresh() }
        guard loaded else { completion(.failure(CraftNativeActionError(code: "STORAGE_ERROR", message: "Health delivery state is unavailable"))); return }
        do {
            switch method {
            case "status": completion(.success(["types": types, "frequency": frequency, "pendingBatches": state.batches.count, "errors": errors]))
            case "refresh": refresh(); completion(.success(true))
            case "pending":
                let data = try JSONEncoder().encode(Array(state.batches.prefix(20)))
                completion(.success(try JSONSerialization.jsonObject(with: data)))
            case "acknowledge":
                guard let ids = args.first as? [String], ids.count <= 20 else {
                    completion(.failure(CraftNativeActionError(code: "INVALID_ARGUMENT", message: "acknowledge needs up to 20 batch ids"))); return
                }
                var next = state
                let acknowledged = Set(ids)
                next.batches.removeAll { acknowledged.contains($0.id) }
                try persistence.save(next)
                state = next
                refresh()
                completion(.success(true))
            default: completion(.failure(CraftNativeActionError(code: "UNKNOWN_ACTION", message: "Unknown HealthBackground action")))
            }
        } catch { completion(.failure(CraftNativeActionError(code: "STORAGE_ERROR", message: "Health delivery state could not be saved"))) }
    }
}

private final class CraftUnavailableHealthBackgroundSource: CraftHealthBackgroundSource {
    func disable(type: String) {}
    func observe(type: String, update: @escaping (Error?, @escaping () -> Void) -> Void) -> () -> Void { {} }
    func enable(type: String, frequency: String, completion: @escaping (Error?) -> Void) { completion(CraftHealthBackgroundError.unavailable) }
    func read(type: String, anchor: Data?, completion: @escaping (Result<CraftHealthBackgroundPage, Error>) -> Void) -> () -> Void { completion(.failure(CraftHealthBackgroundError.unavailable)); return {} }
}

#if CRAFT_PERMISSION_HEALTH
private final class CraftHealthKitBackgroundSource: CraftHealthBackgroundSource {
    private var store: HKHealthStore? { CraftHealth.shared.healthStore }
    private func sampleType(_ name: String) -> HKSampleType? {
        if name == "sleep" { return HKCategoryType.categoryType(forIdentifier: .sleepAnalysis) }
        if name == "workouts" { return HKObjectType.workoutType() }
        return CraftHealth.healthQuantity(name)?.type
    }
    func disable(type: String) {
        guard let store, let sample = sampleType(type) else { return }
        store.disableBackgroundDelivery(for: sample) { _, _ in }
    }
    func observe(type: String, update: @escaping (Error?, @escaping () -> Void) -> Void) -> () -> Void {
        guard let store, let sample = sampleType(type) else { return {} }
        let query = HKObserverQuery(sampleType: sample, predicate: nil) { _, completion, error in
            DispatchQueue.main.async { update(error, completion) }
        }
        store.execute(query)
        return { store.stop(query) }
    }
    func enable(type: String, frequency: String, completion: @escaping (Error?) -> Void) {
        guard let store, let sample = sampleType(type) else { completion(CraftHealthBackgroundError.unavailable); return }
        let value: HKUpdateFrequency = ["immediate": .immediate, "hourly": .hourly, "daily": .daily, "weekly": .weekly][frequency] ?? .hourly
        store.enableBackgroundDelivery(for: sample, frequency: value) { success, error in
            DispatchQueue.main.async { completion(success ? nil : error ?? CraftHealthBackgroundError.unavailable) }
        }
    }
    func read(type: String, anchor: Data?, completion: @escaping (Result<CraftHealthBackgroundPage, Error>) -> Void) -> () -> Void {
        guard let store, let sample = sampleType(type) else { completion(.failure(CraftHealthBackgroundError.unavailable)); return {} }
        let saved: HKQueryAnchor?
        do {
            saved = try anchor.map { data in
                guard let value = try NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data) else { throw CraftHealthBackgroundError.invalidAnchor }
                return value
            }
        } catch { completion(.failure(error)); return {} }
        let query = HKAnchoredObjectQuery(type: sample, predicate: nil, anchor: saved, limit: 250) { _, samples, deleted, anchor, error in
            let answer: Result<CraftHealthBackgroundPage, Error>
            do {
                if let error { throw error }
                guard let anchor else { throw CraftHealthBackgroundError.missingAnchor }
                let data = try NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)
                let records = (samples ?? []).map { sample -> CraftHealthBackgroundSample in
                    var record = CraftHealthBackgroundSample(id: sample.uuid.uuidString, startDate: sample.startDate.timeIntervalSince1970 * 1000, endDate: sample.endDate.timeIntervalSince1970 * 1000)
                    if let quantity = sample as? HKQuantitySample, let spec = CraftHealth.healthQuantity(type) {
                        record.value = quantity.quantity.doubleValue(for: spec.unit)
                        record.unit = spec.unit.unitString
                    } else if let category = sample as? HKCategorySample { record.category = category.value }
                    else if let workout = sample as? HKWorkout { record.workoutActivity = workout.workoutActivityType.rawValue; record.durationSeconds = workout.duration }
                    return record
                }
                answer = .success(CraftHealthBackgroundPage(anchor: data, samples: records, deleted: (deleted ?? []).map { $0.uuid.uuidString }, more: records.count + (deleted?.count ?? 0) >= 250))
            } catch { answer = .failure(error) }
            DispatchQueue.main.async { completion(answer) }
        }
        store.execute(query)
        return { store.stop(query) }
    }
}
#endif
