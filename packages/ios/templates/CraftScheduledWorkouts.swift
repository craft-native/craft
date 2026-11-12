import Foundation
#if CRAFT_SCHEDULED_WORKOUTS
import HealthKit
import WorkoutKit
#endif

/// A scheduling call that did not happen: the message a page sees, and the
/// bridge's error code.
struct CraftScheduledWorkoutsError: Error {
    let message: String
    var code: String = "CRAFT_ERROR"
}

/// Structured workouts scheduled onto the paired Apple Watch through
/// WorkoutKit's `WorkoutScheduler` (iOS 17+): each appears in the watch's
/// Workout app on its day, steps, targets and alerts included.
///
/// One service for both sides: the page's `craft.scheduledWorkouts` (actions
/// `scheduledWorkouts` and `scheduledWorkoutsRequestAuthorization`, which
/// waits on the person) and a native screen's `ScheduledWorkouts` module.
///
/// WorkoutKit is compiled in only with `enableScheduledWorkouts`, which sets
/// the `CRAFT_SCHEDULED_WORKOUTS` condition, so an app that does not schedule
/// workouts does not link it. Without it (or below iOS 17) `isSupported`
/// answers false, `authorization` answers `unsupported`, and everything else
/// rejects UNSUPPORTED.
///
/// A plan is plain JSON (SI units):
///
///   { id: UUID, date: 'YYYY-MM-DD', hour?, minute?, workout: {
///       activity: HKWorkoutActivityType case name, location: 'indoor' | 'outdoor' | 'unknown',
///       swimmingLocation?: 'pool' | 'openWater', poolLengthMeters?, displayName,
///       warmup?: step, cooldown?: step,
///       blocks: [{ iterations, steps: [{ purpose: 'work' | 'recovery', step }] }] } }
///   step = { goal: { type: 'open' | 'time' (seconds) | 'distance' (meters) | 'energy' (kilocalories) },
///            alert?: { type: 'heartRate' | 'power' | 'speed' | 'cadence', min, max } | { type: 'heartRateZone' | 'powerZone', zone },
///            displayName? }
///
/// An activity or a goal WorkoutKit refuses rejects the call, naming it; an
/// alert it refuses is dropped and its step kept (`droppedAlerts`).
///
/// Simulator builds can stand in a scheduler with the
/// `CraftFakeWorkoutScheduler` default (`xcrun simctl spawn booted defaults
/// write <bundle id> CraftFakeWorkoutScheduler -bool YES`): plans are still
/// built and checked by WorkoutKit, then kept in UserDefaults instead of on a
/// watch, which a simulator never has. `CraftFakeWorkoutSchedulerAuthorization`
/// (a string) presets its answer to `denied`, `restricted` or `authorized`.
final class CraftScheduledWorkouts {
    typealias Completion = (Result<Any, CraftScheduledWorkoutsError>) -> Void

    static let shared = CraftScheduledWorkouts()

    /// The call by method, with its options as the bridge sends them; answered on main.
    func perform(method: String, args: [Any], completion: @escaping Completion) {
        let options = args.first as? [String: Any] ?? [:]
        let done: Completion = { result in DispatchQueue.main.async { completion(result) } }
        #if CRAFT_SCHEDULED_WORKOUTS
        if #available(iOS 17.0, *) {
            Task { done(await CraftWorkoutKitScheduler.shared.perform(method: method, options: options)) }
            return
        }
        #endif
        done(Self.unsupported(method: method))
    }

    /// The answer where WorkoutKit is not there: compiled out, or below iOS 17.
    static func unsupported(method: String) -> Result<Any, CraftScheduledWorkoutsError> {
        switch method {
        case "isSupported": return .success(false)
        case "authorization", "requestAuthorization": return .success("unsupported")
        case "list", "schedule", "remove", "removeAll":
            return .failure(CraftScheduledWorkoutsError(message: "unsupported", code: "UNSUPPORTED"))
        default:
            return .failure(CraftScheduledWorkoutsError(message: "Unsupported ScheduledWorkouts method: \(method)", code: "UNKNOWN_ACTION"))
        }
    }
}

#if CRAFT_SCHEDULED_WORKOUTS

/// What the scheduler keeps: a plan's id on a day, and whether it was done.
@available(iOS 17.0, *)
struct CraftScheduledWorkoutEntry {
    let id: UUID
    let date: DateComponents
    let complete: Bool
    /// The plan itself, which WorkoutKit needs to remove it; nil from the stand-in.
    let plan: WorkoutPlan?

    /// `{ id, date, hour?, minute?, complete }`, the id lowercase.
    var json: [String: Any] {
        var out: [String: Any] = ["id": id.uuidString.lowercased(), "complete": complete]
        if let year = date.year, let month = date.month, let day = date.day {
            out["date"] = String(format: "%04d-%02d-%02d", year, month, day)
        }
        if let hour = date.hour { out["hour"] = hour }
        if let minute = date.minute { out["minute"] = minute }
        return out
    }
}

/// WorkoutKit's scheduler, or the simulator's stand-in.
@available(iOS 17.0, *)
protocol CraftWorkoutStore: AnyObject {
    var isSupported: Bool { get }
    var maxCount: Int { get }
    func authorization() async -> String
    func requestAuthorization() async -> String
    func entries() async -> [CraftScheduledWorkoutEntry]
    func schedule(_ plan: WorkoutPlan, at date: DateComponents) async
    func remove(_ entry: CraftScheduledWorkoutEntry) async
    func removeAll() async
}

@available(iOS 17.0, *)
func craftWorkoutAuthorization(_ state: WorkoutScheduler.AuthorizationState) -> String {
    switch state {
    case .authorized: return "authorized"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "notDetermined"
    }
}

@available(iOS 17.0, *)
final class CraftSystemWorkoutStore: CraftWorkoutStore {
    var isSupported: Bool { WorkoutScheduler.isSupported }
    var maxCount: Int { WorkoutScheduler.maxAllowedScheduledWorkoutCount }
    func authorization() async -> String { craftWorkoutAuthorization(await WorkoutScheduler.shared.authorizationState) }
    func requestAuthorization() async -> String { craftWorkoutAuthorization(await WorkoutScheduler.shared.requestAuthorization()) }
    func entries() async -> [CraftScheduledWorkoutEntry] {
        await WorkoutScheduler.shared.scheduledWorkouts.map {
            CraftScheduledWorkoutEntry(id: $0.plan.id, date: $0.date, complete: $0.complete, plan: $0.plan)
        }
    }
    func schedule(_ plan: WorkoutPlan, at date: DateComponents) async { await WorkoutScheduler.shared.schedule(plan, at: date) }
    func remove(_ entry: CraftScheduledWorkoutEntry) async {
        guard let plan = entry.plan else { return }
        await WorkoutScheduler.shared.remove(plan, at: entry.date)
    }
    func removeAll() async { await WorkoutScheduler.shared.removeAllWorkouts() }
}

/// Simulator builds only (see `CraftScheduledWorkouts`): plans kept in
/// UserDefaults, as a paired watch would keep them.
@available(iOS 17.0, *)
final class CraftFakeWorkoutStore: CraftWorkoutStore {
    private let key = "CraftFakeScheduledWorkouts"
    private let authorizationKey = "CraftFakeWorkoutSchedulerAuthorization"
    private let defaults = UserDefaults.standard
    let isSupported = true
    var maxCount: Int { WorkoutScheduler.maxAllowedScheduledWorkoutCount }

    func authorization() async -> String { defaults.string(forKey: authorizationKey) ?? "notDetermined" }
    func requestAuthorization() async -> String {
        let current = await authorization()
        guard current == "notDetermined" else { return current }
        defaults.set("authorized", forKey: authorizationKey)
        return "authorized"
    }
    func entries() async -> [CraftScheduledWorkoutEntry] {
        (defaults.array(forKey: key) as? [[String: Any]] ?? []).compactMap { row in
            guard let id = (row["id"] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
            var date = DateComponents()
            date.year = row["year"] as? Int
            date.month = row["month"] as? Int
            date.day = row["day"] as? Int
            date.hour = row["hour"] as? Int
            date.minute = row["minute"] as? Int
            return CraftScheduledWorkoutEntry(id: id, date: date, complete: row["complete"] as? Bool ?? false, plan: nil)
        }
    }
    func schedule(_ plan: WorkoutPlan, at date: DateComponents) async {
        var rows = defaults.array(forKey: key) as? [[String: Any]] ?? []
        var row: [String: Any] = ["id": plan.id.uuidString, "complete": false]
        row["year"] = date.year
        row["month"] = date.month
        row["day"] = date.day
        row["hour"] = date.hour
        row["minute"] = date.minute
        rows.append(row)
        defaults.set(rows, forKey: key)
    }
    func remove(_ entry: CraftScheduledWorkoutEntry) async {
        let rows = (defaults.array(forKey: key) as? [[String: Any]] ?? []).filter { row in
            !((row["id"] as? String).flatMap(UUID.init(uuidString:)) == entry.id
                && row["year"] as? Int == entry.date.year && row["month"] as? Int == entry.date.month
                && row["day"] as? Int == entry.date.day && row["hour"] as? Int == entry.date.hour
                && row["minute"] as? Int == entry.date.minute)
        }
        defaults.set(rows, forKey: key)
    }
    func removeAll() async { defaults.removeObject(forKey: key) }
}

/// The calls, on whichever store this build schedules with.
@available(iOS 17.0, *)
final class CraftWorkoutKitScheduler {
    static let shared = CraftWorkoutKitScheduler(store: CraftWorkoutKitScheduler.makeStore())

    private let store: CraftWorkoutStore

    init(store: CraftWorkoutStore) { self.store = store }

    private static func makeStore() -> CraftWorkoutStore {
        #if targetEnvironment(simulator)
        if UserDefaults.standard.bool(forKey: "CraftFakeWorkoutScheduler") { return CraftFakeWorkoutStore() }
        #endif
        return CraftSystemWorkoutStore()
    }

    private func failure(_ message: String, _ code: String) -> Result<Any, CraftScheduledWorkoutsError> {
        .failure(CraftScheduledWorkoutsError(message: message, code: code))
    }

    func perform(method: String, options: [String: Any]) async -> Result<Any, CraftScheduledWorkoutsError> {
        switch method {
        case "isSupported":
            return .success(store.isSupported)
        case "authorization":
            return .success(store.isSupported ? await store.authorization() : "unsupported")
        case "requestAuthorization":
            return .success(store.isSupported ? await store.requestAuthorization() : "unsupported")
        case "list", "schedule", "remove", "removeAll":
            guard store.isSupported else { return failure("unsupported", "UNSUPPORTED") }
            guard await store.authorization() == "authorized" else {
                return failure("Scheduling workouts on the Apple Watch has not been allowed", "NOT_AUTHORIZED")
            }
            switch method {
            case "list": return .success(await store.entries().map(\.json))
            case "schedule": return await schedule(options)
            case "remove": return await remove(id: options["id"] as? String)
            default:
                let count = await store.entries().count
                await store.removeAll()
                return .success(count)
            }
        default:
            return failure("Unsupported ScheduledWorkouts method: \(method)", "UNKNOWN_ACTION")
        }
    }

    private func schedule(_ body: [String: Any]) async -> Result<Any, CraftScheduledWorkoutsError> {
        let built: CraftWorkoutPlanBuilder.Built
        switch CraftWorkoutPlanBuilder.build(body) {
        case .success(let value): built = value
        case .failure(let error): return .failure(error)
        }
        let existing = await store.entries().filter { $0.id == built.plan.id }
        let sameDay = existing.contains { CraftWorkoutPlanBuilder.sameMoment($0.date, built.date) }
        if !sameDay {
            // A plan id lives on one day: scheduling it again moves it.
            let others = await store.entries().count - existing.count
            guard others < store.maxCount else {
                return failure("The Apple Watch holds at most \(store.maxCount) scheduled workouts; remove one first", "LIMIT_REACHED")
            }
            for entry in existing { await store.remove(entry) }
            await store.schedule(built.plan, at: built.date)
            // WorkoutScheduler.schedule neither throws nor answers; what it
            // kept is the answer (nothing, without a paired watch).
            let kept = await store.entries().contains { $0.id == built.plan.id && CraftWorkoutPlanBuilder.sameMoment($0.date, built.date) }
            guard kept else {
                return failure("WorkoutKit did not keep the workout. Is an Apple Watch paired with the Workout app installed?", "NOT_SCHEDULED")
            }
        }
        var out: [String: Any] = ["id": built.plan.id.uuidString.lowercased()]
        if !built.droppedAlerts.isEmpty { out["droppedAlerts"] = built.droppedAlerts }
        return .success(out)
    }

    private func remove(id: String?) async -> Result<Any, CraftScheduledWorkoutsError> {
        guard let id, let uuid = UUID(uuidString: id) else {
            return failure("remove needs a plan id (a UUID)", "INVALID_ARGUMENT")
        }
        let matching = await store.entries().filter { $0.id == uuid }
        for entry in matching { await store.remove(entry) }
        return .success(!matching.isEmpty)
    }
}

/// A plan's JSON turned into WorkoutKit's types, checked the way WorkoutKit
/// checks them (`CustomWorkout.supportsActivity`, `supportsGoal`,
/// `supportsAlert`). Pure: no scheduler, so it is unit tested on its own.
@available(iOS 17.0, *)
enum CraftWorkoutPlanBuilder {
    struct Built {
        let plan: WorkoutPlan
        let date: DateComponents
        /// Each alert WorkoutKit refused, by where it was ("block 1 step 2: power").
        let droppedAlerts: [String]
    }

    static let activities: [String: HKWorkoutActivityType] = [
        "running": .running, "cycling": .cycling, "swimming": .swimming, "walking": .walking,
        "hiking": .hiking, "traditionalStrengthTraining": .traditionalStrengthTraining,
        "functionalStrengthTraining": .functionalStrengthTraining, "rowing": .rowing, "yoga": .yoga,
        "flexibility": .flexibility, "crossTraining": .crossTraining, "elliptical": .elliptical,
        "highIntensityIntervalTraining": .highIntensityIntervalTraining, "other": .other,
        "coreTraining": .coreTraining, "mixedCardio": .mixedCardio, "stairClimbing": .stairClimbing,
        "stairs": .stairs, "stepTraining": .stepTraining, "pilates": .pilates, "cardioDance": .cardioDance,
        "kickboxing": .kickboxing, "boxing": .boxing, "jumpRope": .jumpRope, "cooldown": .cooldown,
        "crossCountrySkiing": .crossCountrySkiing, "paddleSports": .paddleSports,
        "handCycling": .handCycling, "wheelchairRunPace": .wheelchairRunPace, "wheelchairWalkPace": .wheelchairWalkPace,
    ]

    static let locations: [String: HKWorkoutSessionLocationType] = ["indoor": .indoor, "outdoor": .outdoor, "unknown": .unknown]

    private static func refuse(_ message: String) -> Result<Built, CraftScheduledWorkoutsError> {
        .failure(CraftScheduledWorkoutsError(message: message, code: "INVALID_ARGUMENT"))
    }

    private static func number(_ value: Any?) -> Double? {
        // JSON's true and false arrive as NSNumber too; they are not numbers here.
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let double = value.doubleValue
        return double.isFinite ? double : nil
    }

    /// A number as a whole one, toward zero, or nil when no `Int` holds it.
    /// `Int(_:)` traps there, and these come from the caller: an `hour` of
    /// `1e30` ended the process where it should have been refused (#510).
    private static func whole(_ value: Any?) -> Int? {
        number(value).flatMap { Int(exactly: $0.rounded(.towardZero)) }
    }

    /// Two schedule dates as WorkoutKit compares them: the day and the time of day.
    static func sameMoment(_ a: DateComponents, _ b: DateComponents) -> Bool {
        a.year == b.year && a.month == b.month && a.day == b.day && (a.hour ?? 0) == (b.hour ?? 0) && (a.minute ?? 0) == (b.minute ?? 0)
    }

    /// 'YYYY-MM-DD' plus the time of day (07:00 when not given), local.
    static func date(_ body: [String: Any]) -> DateComponents? {
        guard let text = body["date"] as? String else { return nil }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        let hour = body["hour"] == nil || body["hour"] is NSNull ? 7 : whole(body["hour"])
        let minute = body["minute"] == nil || body["minute"] is NSNull ? 0 : whole(body["minute"])
        guard let hour, let minute, (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        // A day that does not exist (2026-02-30) is refused, not rolled over.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard let real = calendar.date(from: components),
              calendar.component(.day, from: real) == day, calendar.component(.month, from: real) == month else { return nil }
        components.hour = hour
        components.minute = minute
        return components
    }

    static func goal(_ value: Any?) -> Result<(goal: WorkoutGoal, name: String), CraftScheduledWorkoutsError> {
        let body = value as? [String: Any] ?? [:]
        let type = body["type"] as? String ?? (value == nil ? "open" : "")
        func positive(_ key: String) -> Double? { number(body[key]).flatMap { $0 > 0 ? $0 : nil } }
        switch type {
        case "open": return .success((.open, "open"))
        case "time":
            guard let seconds = positive("seconds") else { break }
            return .success((.time(seconds, .seconds), "time"))
        case "distance":
            guard let meters = positive("meters") else { break }
            return .success((.distance(meters, .meters), "distance"))
        case "energy":
            guard let kilocalories = positive("kilocalories") else { break }
            return .success((.energy(kilocalories, .kilocalories), "energy"))
        default:
            return .failure(CraftScheduledWorkoutsError(message: "Unknown goal type '\(type)'", code: "INVALID_ARGUMENT"))
        }
        return .failure(CraftScheduledWorkoutsError(message: "A \(type) goal needs a positive number", code: "INVALID_ARGUMENT"))
    }

    /// The alert, or why it was left out.
    static func alert(_ value: Any?) -> Result<(alert: any WorkoutAlert, name: String), CraftScheduledWorkoutsError> {
        let body = value as? [String: Any] ?? [:]
        let type = body["type"] as? String ?? ""
        func invalid(_ why: String) -> Result<(alert: any WorkoutAlert, name: String), CraftScheduledWorkoutsError> {
            .failure(CraftScheduledWorkoutsError(message: "\(type.isEmpty ? "alert" : type) \(why)", code: "INVALID_ARGUMENT"))
        }
        func range() -> ClosedRange<Double>? {
            guard let a = number(body["min"]), let b = number(body["max"]), a >= 0, b >= 0, max(a, b) > 0 else { return nil }
            return min(a, b)...max(a, b)
        }
        func zone() -> Int? {
            guard let value = number(body["zone"]), value >= 1, value.rounded() == value else { return nil }
            return Int(exactly: value)
        }
        switch type {
        case "heartRate":
            guard let range = range() else { return invalid("needs min and max") }
            return .success((.heartRate(range), type))
        case "heartRateZone":
            guard let zone = zone() else { return invalid("needs a zone from 1") }
            return .success((.heartRate(zone: zone), type))
        case "power":
            guard let range = range() else { return invalid("needs min and max") }
            return .success((.power(range, unit: .watts), type))
        case "powerZone":
            guard let zone = zone() else { return invalid("needs a zone from 1") }
            return .success((.power(zone: zone), type))
        case "speed":
            guard let range = range() else { return invalid("needs min and max") }
            return .success((.speed(range, unit: .metersPerSecond, metric: .current), type))
        case "cadence":
            guard let range = range() else { return invalid("needs min and max") }
            return .success((.cadence(range), type))
        default:
            return invalid("is not an alert WorkoutKit knows")
        }
    }

    static func build(_ body: [String: Any]) -> Result<Built, CraftScheduledWorkoutsError> {
        guard let idText = body["id"] as? String, let id = UUID(uuidString: idText) else {
            return refuse("A scheduled workout needs an id (a UUID)")
        }
        guard let date = date(body) else {
            return refuse("A scheduled workout needs a date ('YYYY-MM-DD') and, when given, an hour 0-23 and a minute 0-59")
        }
        guard let workout = body["workout"] as? [String: Any] else { return refuse("A scheduled workout needs a workout") }
        let activityName = workout["activity"] as? String ?? ""
        guard let activity = activities[activityName] else {
            return refuse("WorkoutKit has no activity '\(activityName)'")
        }
        guard CustomWorkout.supportsActivity(activity) else {
            return refuse("WorkoutKit cannot schedule a custom \(activityName) workout")
        }
        let locationName = workout["location"] as? String ?? "unknown"
        guard var location = locations[locationName] else {
            return refuse("A workout's location is indoor, outdoor or unknown, not '\(locationName)'")
        }
        // CustomWorkout has no swimming location of its own (and no pool
        // length; the watch asks for that when the swim starts): a pool swim
        // is indoor, open water outdoor.
        if activity == .swimming, location == .unknown {
            switch workout["swimmingLocation"] as? String {
            case "openWater": location = .outdoor
            case "pool", nil: location = .indoor
            default: break
            }
        }
        let context = "\(activityName) (\(locationName == "unknown" && location != .unknown ? (location == .indoor ? "indoor" : "outdoor") : locationName))"
        var dropped: [String] = []

        func step(_ value: Any?, at place: String) -> Result<WorkoutStep, CraftScheduledWorkoutsError> {
            guard let body = value as? [String: Any] else {
                return .failure(CraftScheduledWorkoutsError(message: "\(place) needs a goal", code: "INVALID_ARGUMENT"))
            }
            let parsedGoal: (goal: WorkoutGoal, name: String)
            switch goal(body["goal"]) {
            case .success(let value): parsedGoal = value
            case .failure(let error): return .failure(CraftScheduledWorkoutsError(message: "\(place): \(error.message)", code: error.code))
            }
            guard CustomWorkout.supportsGoal(parsedGoal.goal, activity: activity, location: location) else {
                return .failure(CraftScheduledWorkoutsError(message: "WorkoutKit refuses a \(parsedGoal.name) goal for \(context) (\(place))", code: "UNSUPPORTED_GOAL"))
            }
            var result = WorkoutStep(goal: parsedGoal.goal)
            if let alertBody = body["alert"], !(alertBody is NSNull) {
                switch alert(alertBody) {
                case .success(let parsed):
                    if CustomWorkout.supportsAlert(parsed.alert, activity: activity, location: location) {
                        result.alert = parsed.alert
                    } else {
                        dropped.append("\(place): \(parsed.name) alert, which WorkoutKit refuses for \(context)")
                    }
                case .failure(let error):
                    dropped.append("\(place): \(error.message)")
                }
            }
            if #available(iOS 18.0, *), let name = (body["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                result.displayName = String(name.prefix(64))
            }
            return .success(result)
        }

        var warmup: WorkoutStep?
        if let value = workout["warmup"], !(value is NSNull) {
            switch step(value, at: "warmup") {
            case .success(let parsed): warmup = parsed
            case .failure(let error): return .failure(error)
            }
        }
        var cooldown: WorkoutStep?
        if let value = workout["cooldown"], !(value is NSNull) {
            switch step(value, at: "cooldown") {
            case .success(let parsed): cooldown = parsed
            case .failure(let error): return .failure(error)
            }
        }
        var blocks: [IntervalBlock] = []
        for (blockIndex, value) in (workout["blocks"] as? [Any] ?? []).enumerated() {
            let block = value as? [String: Any] ?? [:]
            let iterations = whole(block["iterations"] ?? 1) ?? 0
            guard iterations >= 1 else { return refuse("block \(blockIndex + 1) needs iterations of 1 or more") }
            var steps: [IntervalStep] = []
            for (stepIndex, entry) in (block["steps"] as? [Any] ?? []).enumerated() {
                let place = "block \(blockIndex + 1) step \(stepIndex + 1)"
                let entry = entry as? [String: Any] ?? [:]
                let purpose: IntervalStep.Purpose
                switch entry["purpose"] as? String {
                case "work": purpose = .work
                case "recovery": purpose = .recovery
                default: return refuse("\(place) needs a purpose: work or recovery")
                }
                switch step(entry["step"], at: place) {
                case .success(let parsed): steps.append(IntervalStep(purpose, step: parsed))
                case .failure(let error): return .failure(error)
                }
            }
            guard !steps.isEmpty else { return refuse("block \(blockIndex + 1) has no steps") }
            blocks.append(IntervalBlock(steps: steps, iterations: iterations))
        }
        guard warmup != nil || cooldown != nil || !blocks.isEmpty else {
            return refuse("A scheduled workout needs at least one step")
        }
        let displayName = (workout["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = CustomWorkout(
            activity: activity,
            location: location,
            displayName: displayName?.isEmpty == false ? displayName : nil,
            warmup: warmup,
            blocks: blocks,
            cooldown: cooldown
        )
        return .success(Built(plan: WorkoutPlan(.custom(custom), id: id), date: date, droppedAlerts: dropped))
    }
}

#endif
