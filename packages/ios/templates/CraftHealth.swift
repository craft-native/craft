import CoreLocation
import Foundation
import HealthKit

/// A HealthKit read or write that did not happen: the message a page sees,
/// and the bridge's error code.
struct CraftHealthError: Error {
    let message: String
    var code: String = "CRAFT_ERROR"
}

/// A separate delegate keeps the iOS 17+ HealthKit session types out of the
/// iOS 16-compatible CraftHealth declaration. The owning service retains it
/// for the lifetime of the session.
@available(iOS 17.0, *)
private final class CraftHealthWorkoutDelegate: NSObject, HKWorkoutSessionDelegate {
    private let id: () -> String
    private let emit: ([String: Any]) -> Void

    init(id: @escaping () -> String, emit: @escaping ([String: Any]) -> Void) {
        self.id = id
        self.emit = emit
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        emit(["id": id(), "event": "state", "state": Self.stateName(toState), "date": date.timeIntervalSince1970 * 1000])
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        emit(["id": id(), "event": "error", "message": error.localizedDescription])
    }

    private static func stateName(_ state: HKWorkoutSessionState) -> String {
        switch state {
        case .notStarted: return "notStarted"
        case .prepared: return "prepared"
        case .running: return "running"
        case .paused: return "paused"
        case .stopped: return "stopped"
        case .ended: return "ended"
        @unknown default: return "unknown"
        }
    }
}

@available(iOS 26.0, *)
private final class CraftHealthWorkoutBuilderDelegate: NSObject, HKLiveWorkoutBuilderDelegate {
    weak var owner: CraftHealth?

    init(owner: CraftHealth) { self.owner = owner }

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        owner?.emitLiveWorkoutMetrics(workoutBuilder)
    }

    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}

/// Apple Health for the whole app: the web page's bridge (`craft.health` in
/// the hybrid's web view, CraftApp.swift) and native screens alike
/// (`Health` through CraftNativeActions), so a screen drawn natively reads
/// and writes Apple Health exactly as a page does. One HKHealthStore for the
/// process, as Apple asks. Every answer is delivered on the main queue so the
/// native-screen JavaScript bridge can safely resume its pending call.
final class CraftHealth {
    typealias Completion = (Result<Any, CraftHealthError>) -> Void

    static let shared = CraftHealth()

    private func completeOnMain(_ completion: @escaping Completion) -> Completion {
        { result in
            if Thread.isMainThread {
                completion(result)
            } else {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// Nil where Apple Health is not on this device (an iPad without it).
    let healthStore: HKHealthStore? = HKHealthStore.isHealthDataAvailable() ? HKHealthStore() : nil

    /// A native screen's call (`Health` in CraftNativeActions), by method and arguments as the bridge sends them.
    func perform(method: String, args: [Any], completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        let options = { (index: Int) in args.count > index ? args[index] as? [String: Any] ?? [:] : [:] }
        switch method {
        case "requestAuthorization":
            requestAuthorization(types: args.first as? [String] ?? [], readOnly: options(1)["write"] as? Bool == false || options(1)["readOnly"] as? Bool == true, completion: completion)
        case "getData":
            guard let type = args.first as? String else { return completion(.failure(CraftHealthError(message: "getData needs a type", code: "INVALID_ARGUMENT"))) }
            getData(type: type, startDate: options(1)["startDate"] as? Double, endDate: options(1)["endDate"] as? Double, completion: completion)
        case "saveData":
            guard let type = args.first as? String,
                  args.count > 1,
                  let value = (args[1] as? NSNumber)?.doubleValue else {
                return completion(.failure(CraftHealthError(message: "saveData needs a type and numeric value", code: "INVALID_ARGUMENT")))
            }
            saveData(type: type, value: value, options: options(2), completion: completion)
        case "saveWorkout":
            saveWorkout(body: options(0), completion: completion)
        case "getWorkouts":
            getWorkouts(startDate: options(0)["startDate"] as? Double, endDate: options(0)["endDate"] as? Double, limit: options(0)["limit"] as? Int, completion: completion)
        case "getDailyStatistics":
            guard let type = args.first as? String else { return completion(.failure(CraftHealthError(message: "getDailyStatistics needs a type", code: "INVALID_ARGUMENT"))) }
            getDailyStatistics(type: type, startDate: options(1)["startDate"] as? Double, endDate: options(1)["endDate"] as? Double, completion: completion)
        case "getHeartRateSamples":
            getHeartRateSamples(startDate: options(0)["startDate"] as? Double, endDate: options(0)["endDate"] as? Double, limit: options(0)["limit"] as? Int, completion: completion)
        case "getSamples":
            guard let type = args.first as? String else { return completion(.failure(CraftHealthError(message: "getSamples needs a type", code: "INVALID_ARGUMENT"))) }
            getSamples(type: type, startDate: options(1)["startDate"] as? Double, endDate: options(1)["endDate"] as? Double, limit: options(1)["limit"] as? Int, completion: completion)
        case "getSleepIntervals":
            getSleepIntervals(startDate: options(0)["startDate"] as? Double, endDate: options(0)["endDate"] as? Double, completion: completion)
        case "saveMindfulSession":
            saveMindfulSession(body: options(0), completion: completion)
        case "getMindfulSessions":
            getMindfulSessions(startDate: options(0)["startDate"] as? Double, endDate: options(0)["endDate"] as? Double, limit: options(0)["limit"] as? Int, completion: completion)
        case "startHeartRateUpdates":
            startHeartRateUpdates(since: options(0)["since"] as? Double, completion: completion)
        case "stopHeartRateUpdates":
            stopHeartRateUpdates(completion: completion)
        case "startWorkout":
            startWorkout(body: options(0), completion: completion)
        case "pauseWorkout":
            pauseWorkout(completion: completion)
        case "resumeWorkout":
            resumeWorkout(completion: completion)
        case "endWorkout":
            endWorkout(completion: completion)
        case "discardWorkout":
            discardWorkout(completion: completion)
        default:
            completion(.failure(CraftHealthError(message: "Unsupported Health method", code: "UNKNOWN_ACTION")))
        }
    }

    func requestAuthorization(types: [String], readOnly: Bool = false, completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }

        var readTypes: Set<HKObjectType> = []
        var shareTypes: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let routeType = HKSeriesType.workoutRoute() as? HKSampleType {
            shareTypes.insert(routeType)
        }

        for type in types {
            switch type {
            case "steps":
                if let stepType = HKQuantityType.quantityType(forIdentifier: .stepCount) {
                    readTypes.insert(stepType)
                }
            case "heartRate":
                if let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
                    readTypes.insert(heartType)
                }
            case "activeEnergy":
                if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                    readTypes.insert(energyType)
                    shareTypes.insert(energyType)
                }
            case "distance":
                if let distanceType = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) {
                    readTypes.insert(distanceType)
                    shareTypes.insert(distanceType)
                }
            case "workouts":
                readTypes.insert(HKObjectType.workoutType())
                // A workout's own heart rate and energy are read through
                // these; without them every workout comes back bare.
                if let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate) {
                    readTypes.insert(heartType)
                }
                if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) {
                    readTypes.insert(energyType)
                }
            case "restingHeartRate":
                if let restingType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
                    readTypes.insert(restingType)
                }
            case "heartRateVariability":
                if let hrvType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
                    readTypes.insert(hrvType)
                }
            case "bodyMass":
                if let massType = HKQuantityType.quantityType(forIdentifier: .bodyMass) {
                    readTypes.insert(massType)
                }
            case "sleep":
                if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
                    readTypes.insert(sleepType)
                }
            case "mindful":
                // Mindful minutes: a meditation or breathing session. Read
                // to show them, and (unless read only) written by an app
                // that times them.
                if let mindfulType = HKObjectType.categoryType(forIdentifier: .mindfulSession) {
                    readTypes.insert(mindfulType)
                    shareTypes.insert(mindfulType)
                }
            case "bloodGlucose", "insulinDelivery":
                // A CGM, meter, pump or closed loop's own writes: read
                // only, never written back, so the sheet only asks to read.
                if let diabetesType = Self.healthQuantity(type)?.type {
                    readTypes.insert(diabetesType)
                }
            case "dietaryEnergy", "dietaryProtein", "dietaryCarbohydrates", "dietaryFat":
                // What a food log (MyFitnessPal, Lose It!, Cronometer...)
                // writes to Apple Health. Request the write grant too unless
                // the caller explicitly asked for a read-only authorization.
                if let dietaryType = Self.healthQuantity(type)?.type {
                    readTypes.insert(dietaryType)
                    if !readOnly { shareTypes.insert(dietaryType) }
                }
            default:
                completion(.failure(CraftHealthError(message: "Unknown health data type: \(type)", code: "INVALID_ARGUMENT")))
                return
            }
        }

        // A page that only reads asks only to read: the sheet then says
        // "access", not "access and update".
        if readOnly { shareTypes.removeAll() }
        healthStore.requestAuthorization(toShare: shareTypes, read: readTypes) { [weak self] success, error in
            if success {
                completion(.success(true))
            } else {
                completion(.failure(CraftHealthError(message: error?.localizedDescription ?? "Authorization failed")))
            }
        }
    }

    func getData(type: String, startDate: Double?, endDate: Double?, completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }

        guard let spec = Self.healthQuantity(type), let qType = spec.type else {
            completion(.failure(CraftHealthError(message: "Unknown health data type")))
            return
        }
        let qUnit = spec.unit

        let start = startDate != nil ? Date(timeIntervalSince1970: startDate! / 1000) : Calendar.current.date(byAdding: .day, value: -7, to: Date())!
        let end = endDate != nil ? Date(timeIntervalSince1970: endDate! / 1000) : Date()

        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        // A discrete type (heart rate, weight) has no sum: HealthKit fails
        // the whole query when asked for one, which is what heart rate
        // used to do. Each type is asked for the statistic it has.
        let query = HKStatisticsQuery(quantityType: qType, quantitySamplePredicate: predicate, options: spec.options) { [weak self] _, result, error in
            if let error = error {
                // No samples in the range is an answer, not a failure.
                if (error as? HKError)?.code == .errorNoData {
                    completion(.success(["value": 0, "unit": qUnit.unitString]))
                    return
                }
                completion(.failure(CraftHealthError(message: error.localizedDescription)))
                return
            }

            let value = result.flatMap { Self.statisticValue($0, options: spec.options, unit: qUnit) } ?? 0
            completion(.success(["value": value, "unit": qUnit.unitString]))
        }

        healthStore.execute(query)
    }

    /// Save one quantity sample, primarily a food-log entry. Dates are epoch
    /// milliseconds; an omitted range records an instantaneous sample now.
    func saveData(type: String, value: Double, options: [String: Any], completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }
        guard value.isFinite, value >= 0 else {
            completion(.failure(CraftHealthError(message: "saveData needs a finite, non-negative value", code: "INVALID_ARGUMENT")))
            return
        }
        guard let spec = Self.healthQuantity(type), let qType = spec.type else {
            completion(.failure(CraftHealthError(message: "Unknown health data type: \(type)", code: "INVALID_ARGUMENT")))
            return
        }
        let startValue = options["startDate"] as? Double ?? Date().timeIntervalSince1970 * 1000
        let endValue = options["endDate"] as? Double ?? startValue
        guard startValue.isFinite, endValue.isFinite, endValue >= startValue else {
            completion(.failure(CraftHealthError(message: "saveData needs a valid date range", code: "INVALID_ARGUMENT")))
            return
        }
        let sample = HKQuantitySample(
            type: qType,
            quantity: HKQuantity(unit: spec.unit, doubleValue: value),
            start: Date(timeIntervalSince1970: startValue / 1000),
            end: Date(timeIntervalSince1970: endValue / 1000)
        )
        healthStore.save(sample) { success, error in
            if success {
                completion(.success(["id": sample.uuid.uuidString]))
            } else {
                completion(.failure(CraftHealthError(message: error?.localizedDescription ?? "Health data could not be saved")))
            }
        }
    }

    func saveWorkout(body: [String: Any], completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }
        guard let activityId = body["activityId"] as? String,
              let type = body["type"] as? String,
              let startValue = body["startDate"] as? Double,
              let endValue = body["endDate"] as? Double,
              endValue > startValue else {
            completion(.failure(CraftHealthError(message: "A valid activityId, type, startDate, and endDate are required")))
            return
        }

        let activityType: HKWorkoutActivityType
        switch type {
        case "running": activityType = .running
        case "walking": activityType = .walking
        case "hiking": activityType = .hiking
        case "cycling": activityType = .cycling
        default:
            completion(.failure(CraftHealthError(message: "Unsupported workout type")))
            return
        }

        let distance = (body["distanceMeters"] as? Double).flatMap { value in
            value > 0 ? HKQuantity(unit: .meter(), doubleValue: value) : nil
        }
        let energy = (body["activeEnergyCalories"] as? Double).flatMap { value in
            value > 0 ? HKQuantity(unit: .kilocalorie(), doubleValue: value) : nil
        }
        let start = Date(timeIntervalSince1970: startValue / 1000)
        let end = Date(timeIntervalSince1970: endValue / 1000)
        let workout = HKWorkout(
            activityType: activityType,
            start: start,
            end: end,
            workoutEvents: nil,
            totalEnergyBurned: energy,
            totalDistance: distance,
            metadata: [HKMetadataKeyExternalUUID: activityId, HKMetadataKeyIndoorWorkout: false]
        )

        healthStore.save(workout) { [weak self] success, error in
            guard let self = self else { return }
            guard success else {
                completion(.failure(CraftHealthError(message: error?.localizedDescription ?? "Workout could not be saved")))
                return
            }

            let locations = (body["locations"] as? [[String: Any]] ?? []).compactMap { item -> CLLocation? in
                guard let latitude = item["latitude"] as? Double,
                      let longitude = item["longitude"] as? Double,
                      let timestamp = item["timestamp"] as? Double else { return nil }
                return CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                    altitude: item["altitude"] as? Double ?? 0,
                    horizontalAccuracy: item["accuracy"] as? Double ?? 10,
                    verticalAccuracy: -1,
                    timestamp: Date(timeIntervalSince1970: timestamp / 1000)
                )
            }.filter { $0.timestamp >= start && $0.timestamp <= end }

            guard !locations.isEmpty else {
                completion(.success(["id": workout.uuid.uuidString]))
                return
            }

            let routeBuilder = HKWorkoutRouteBuilder(healthStore: healthStore, device: .local())
            routeBuilder.insertRouteData(locations) { inserted, routeError in
                guard inserted else {
                    completion(.failure(CraftHealthError(message: routeError?.localizedDescription ?? "Workout route could not be saved")))
                    return
                }
                routeBuilder.finishRoute(with: workout, metadata: [HKMetadataKeyExternalUUID: activityId]) { route, finishError in
                    if let finishError = finishError {
                        completion(.failure(CraftHealthError(message: finishError.localizedDescription)))
                    } else {
                        completion(.success([
                            "id": workout.uuid.uuidString,
                            "routeId": route?.uuid.uuidString ?? ""
                        ]))
                    }
                }
            }
        }
    }

    /// The quantity behind each health data type, its unit, and the one
    /// statistic that type supports.
    private static func healthQuantity(_ type: String) -> (type: HKQuantityType?, unit: HKUnit, options: HKStatisticsOptions)? {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        switch type {
        case "steps": return (HKQuantityType.quantityType(forIdentifier: .stepCount), .count(), .cumulativeSum)
        case "activeEnergy": return (HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned), .kilocalorie(), .cumulativeSum)
        case "distance": return (HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning), .meter(), .cumulativeSum)
        case "heartRate": return (HKQuantityType.quantityType(forIdentifier: .heartRate), bpm, .discreteAverage)
        case "restingHeartRate": return (HKQuantityType.quantityType(forIdentifier: .restingHeartRate), bpm, .discreteAverage)
        case "heartRateVariability": return (HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN), .secondUnit(with: .milli), .discreteAverage)
        case "bodyMass": return (HKQuantityType.quantityType(forIdentifier: .bodyMass), .gramUnit(with: .kilo), .mostRecent)
        // A day's food, summed over every meal any app logged: kcal and grams.
        case "dietaryEnergy": return (HKQuantityType.quantityType(forIdentifier: .dietaryEnergyConsumed), .kilocalorie(), .cumulativeSum)
        case "dietaryProtein": return (HKQuantityType.quantityType(forIdentifier: .dietaryProtein), .gram(), .cumulativeSum)
        case "dietaryCarbohydrates": return (HKQuantityType.quantityType(forIdentifier: .dietaryCarbohydrates), .gram(), .cumulativeSum)
        case "dietaryFat": return (HKQuantityType.quantityType(forIdentifier: .dietaryFatTotal), .gram(), .cumulativeSum)
        case "bloodGlucose": return (HKQuantityType.quantityType(forIdentifier: .bloodGlucose), HKUnit(from: "mg/dL"), .discreteAverage)
        case "insulinDelivery": return (HKQuantityType.quantityType(forIdentifier: .insulinDelivery), .internationalUnit(), .cumulativeSum)
        default: return nil
        }
    }

    private static func statisticValue(_ statistics: HKStatistics, options: HKStatisticsOptions, unit: HKUnit) -> Double? {
        if options.contains(.cumulativeSum) { return statistics.sumQuantity()?.doubleValue(for: unit) }
        if options.contains(.mostRecent) { return statistics.mostRecentQuantity()?.doubleValue(for: unit) }
        return statistics.averageQuantity()?.doubleValue(for: unit)
    }

    private static let healthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// A stable name for a workout's activity, independent of the SDK's
    /// raw values, so a page can map it to its own sports.
    private static func workoutTypeName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .cycling: return "cycling"
        case .walking: return "walking"
        case .hiking: return "hiking"
        case .swimming: return "swimming"
        case .rowing: return "rowing"
        case .elliptical: return "elliptical"
        case .stairClimbing, .stairs: return "stairClimbing"
        case .yoga: return "yoga"
        case .pilates: return "pilates"
        case .functionalStrengthTraining, .traditionalStrengthTraining, .coreTraining: return "strength"
        case .highIntensityIntervalTraining: return "hiit"
        case .crossTraining, .mixedCardio: return "crossTraining"
        case .crossCountrySkiing: return "crossCountrySkiing"
        case .downhillSkiing, .snowboarding: return "skiing"
        case .paddleSports: return "paddling"
        case .climbing: return "climbing"
        case .dance, .socialDance, .cardioDance: return "dance"
        case .cooldown, .flexibility, .mindAndBody: return "mobility"
        default: return "other"
        }
    }

    /// Workouts in Apple Health — the watch's, and every app's that
    /// writes there — newest first, with the numbers a training log needs.
    func getWorkouts(startDate: Double?, endDate: Double?, limit: Int?, completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }

        let start = startDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        let end = endDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let newestFirst = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let cap = max(1, min(limit ?? 200, 1000))

        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate, limit: cap, sortDescriptors: [newestFirst]) { [weak self] _, samples, error in
            if let error = error, (error as? HKError)?.code != .errorNoData {
                completion(.failure(CraftHealthError(message: error.localizedDescription)))
                return
            }

            let bpm = HKUnit.count().unitDivided(by: .minute())
            let workouts: [[String: Any]] = (samples as? [HKWorkout] ?? []).map { workout in
                var item: [String: Any] = [
                    "id": workout.uuid.uuidString,
                    "type": Self.workoutTypeName(workout.workoutActivityType),
                    "startDate": workout.startDate.timeIntervalSince1970 * 1000,
                    "endDate": workout.endDate.timeIntervalSince1970 * 1000,
                    "durationSeconds": workout.duration,
                    "sourceName": workout.sourceRevision.source.name,
                    "indoor": (workout.metadata?[HKMetadataKeyIndoorWorkout] as? Bool) ?? false,
                ]
                if let meters = workout.totalDistance?.doubleValue(for: .meter()), meters > 0 {
                    item["distanceMeters"] = meters
                }
                if let ascent = workout.metadata?[HKMetadataKeyElevationAscended] as? HKQuantity {
                    item["elevationGainMeters"] = ascent.doubleValue(for: .meter())
                }
                if #available(iOS 16.0, *) {
                    if let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate),
                       let heart = workout.statistics(for: heartType) {
                        if let average = heart.averageQuantity()?.doubleValue(for: bpm) { item["averageHeartRate"] = average }
                        if let maximum = heart.maximumQuantity()?.doubleValue(for: bpm) { item["maxHeartRate"] = maximum }
                    }
                    if let energyType = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
                       let calories = workout.statistics(for: energyType)?.sumQuantity()?.doubleValue(for: .kilocalorie()) {
                        item["activeEnergyCalories"] = calories
                    }
                } else if let calories = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
                    item["activeEnergyCalories"] = calories
                }
                return item
            }
            completion(.success(workouts))
        }
        healthStore.execute(query)
    }

    /// One value per local day: a sum for steps, energy and distance, an
    /// average for heart rate, resting heart rate and HRV, the latest
    /// weight, and hours asleep for sleep (counted on the day you woke).
    func getDailyStatistics(type: String, startDate: Double?, endDate: Double?, completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }

        let calendar = Calendar.current
        let end = endDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let start = calendar.startOfDay(for: startDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? calendar.date(byAdding: .day, value: -30, to: end)!)

        if type == "sleep" {
            guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
                completion(.failure(CraftHealthError(message: "Sleep data is unavailable")))
                return
            }
            // From the evening before the first day, so its night counts.
            let predicate = HKQuery.predicateForSamples(withStart: calendar.date(byAdding: .hour, value: -12, to: start), end: end, options: [])
            let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { [weak self] _, samples, error in
                if let error = error, (error as? HKError)?.code != .errorNoData {
                    completion(.failure(CraftHealthError(message: error.localizedDescription)))
                    return
                }
                // Time in bed and time awake are not sleep; every asleep
                // stage (and the older single "asleep" value) is.
                let awake: Set<Int> = [HKCategoryValueSleepAnalysis.inBed.rawValue, HKCategoryValueSleepAnalysis.awake.rawValue]
                var secondsByDay: [String: Double] = [:]
                for sample in samples as? [HKCategorySample] ?? [] where !awake.contains(sample.value) {
                    let day = Self.healthDayFormatter.string(from: sample.endDate)
                    secondsByDay[day, default: 0] += sample.endDate.timeIntervalSince(sample.startDate)
                }
                let days = secondsByDay.keys.sorted().map { day -> [String: Any] in
                    ["date": day, "value": (secondsByDay[day]! / 3600 * 100).rounded() / 100, "unit": "hr"]
                }
                completion(.success(days))
            }
            healthStore.execute(query)
            return
        }

        guard let spec = Self.healthQuantity(type), let qType = spec.type else {
            completion(.failure(CraftHealthError(message: "Unknown health data type")))
            return
        }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let query = HKStatisticsCollectionQuery(
            quantityType: qType,
            quantitySamplePredicate: predicate,
            options: spec.options,
            anchorDate: start,
            intervalComponents: DateComponents(day: 1)
        )
        query.initialResultsHandler = { [weak self] _, collection, error in
            if let error = error, (error as? HKError)?.code != .errorNoData {
                completion(.failure(CraftHealthError(message: error.localizedDescription)))
                return
            }
            var days: [[String: Any]] = []
            collection?.enumerateStatistics(from: start, to: end) { statistics, _ in
                guard let value = Self.statisticValue(statistics, options: spec.options, unit: spec.unit) else { return }
                days.append([
                    "date": Self.healthDayFormatter.string(from: statistics.startDate),
                    "value": value,
                    "unit": spec.unit.unitString,
                ])
            }
            completion(.success(days))
        }
        healthStore.execute(query)
    }

    /// Every heart-rate reading between two instants, oldest first: the
    /// beats per minute, when it was taken, and the app and device that
    /// wrote it. A watch's workout readings can arrive as one series
    /// sample; those also carry their count, lowest and highest.
    func getHeartRateSamples(startDate: Double?, endDate: Double?, limit: Int?, completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }
        guard let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
            completion(.failure(CraftHealthError(message: "Heart rate is unavailable")))
            return
        }

        let end = endDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let start = startDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Calendar.current.date(byAdding: .day, value: -1, to: end)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let oldestFirst = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let cap = max(1, min(limit ?? 10_000, 50_000))

        let query = HKSampleQuery(sampleType: heartType, predicate: predicate, limit: cap, sortDescriptors: [oldestFirst]) { _, samples, error in
            if let error = error, (error as? HKError)?.code != .errorNoData {
                completion(.failure(CraftHealthError(message: error.localizedDescription)))
                return
            }
            completion(.success((samples as? [HKQuantitySample] ?? []).map(Self.heartRateRow)))
        }
        healthStore.execute(query)
    }

    /// The types `getSamples` reads, and the unit each answers in.
    private static let sampleUnits: [String: String] = ["bloodGlucose": "mg/dL", "insulinDelivery": "IU", "dietaryCarbohydrates": "g"]

    /// Every glucose reading, insulin dose or carb entry between two
    /// instants, oldest first, as the writing app saved it: its UUID (so a
    /// sync stores it once), value, source and device, plus what a diabetes
    /// app needs to tell readings and doses apart: an insulin dose's reason
    /// (basal or bolus) and a glucose reading's meal time.
    func getSamples(type: String, startDate: Double?, endDate: Double?, limit: Int?, completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }
        guard let unitName = Self.sampleUnits[type], let spec = Self.healthQuantity(type), let sampleType = spec.type else {
            completion(.failure(CraftHealthError(message: "getSamples reads bloodGlucose, insulinDelivery or dietaryCarbohydrates", code: "INVALID_ARGUMENT")))
            return
        }

        let end = endDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let start = startDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Calendar.current.date(byAdding: .day, value: -7, to: end)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let oldestFirst = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let cap = max(1, min(limit ?? 10_000, 50_000))
        let ownBundle = Bundle.main.bundleIdentifier

        let query = HKSampleQuery(sampleType: sampleType, predicate: predicate, limit: cap, sortDescriptors: [oldestFirst]) { _, samples, error in
            if let error = error, (error as? HKError)?.code != .errorNoData {
                completion(.failure(CraftHealthError(message: error.localizedDescription)))
                return
            }
            let rows: [[String: Any]] = (samples as? [HKQuantitySample] ?? []).map { sample in
                let source = sample.sourceRevision.source
                var item: [String: Any] = [
                    "id": sample.uuid.uuidString,
                    "value": sample.quantity.doubleValue(for: spec.unit),
                    "unit": unitName,
                    "startDate": sample.startDate.timeIntervalSince1970 * 1000,
                    "endDate": sample.endDate.timeIntervalSince1970 * 1000,
                    "sourceName": source.name,
                    "sourceBundleId": source.bundleIdentifier,
                    "ownApp": ownBundle != nil && source.bundleIdentifier == ownBundle,
                ]
                if let device = sample.device?.name { item["deviceName"] = device }
                if let reason = sample.metadata?[HKMetadataKeyInsulinDeliveryReason] as? NSNumber {
                    switch HKInsulinDeliveryReason(rawValue: reason.intValue) {
                    case .basal: item["insulinReason"] = "basal"
                    case .bolus: item["insulinReason"] = "bolus"
                    default: break
                    }
                }
                if let meal = sample.metadata?[HKMetadataKeyBloodGlucoseMealTime] as? NSNumber {
                    switch HKBloodGlucoseMealTime(rawValue: meal.intValue) {
                    case .preprandial: item["mealTime"] = "beforeMeal"
                    case .postprandial: item["mealTime"] = "afterMeal"
                    default: break
                    }
                }
                return item
            }
            completion(.success(rows))
        }
        healthStore.execute(query)
    }

    /// One heart-rate sample as a page sees it, from a read or the stream
    /// alike: bpm, when, the app and device that wrote it, a series' count,
    /// lowest and highest, and what the wearer was doing when the watch says.
    private static func heartRateRow(_ sample: HKQuantitySample) -> [String: Any] {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var item: [String: Any] = [
            "bpm": sample.quantity.doubleValue(for: bpm),
            "startDate": sample.startDate.timeIntervalSince1970 * 1000,
            "endDate": sample.endDate.timeIntervalSince1970 * 1000,
            "sourceName": sample.sourceRevision.source.name,
        ]
        if let device = sample.device?.name { item["deviceName"] = device }
        if let model = sample.device?.model { item["deviceModel"] = model }
        if let series = sample as? HKDiscreteQuantitySample, series.count > 1 {
            item["count"] = series.count
            item["min"] = series.minimumQuantity.doubleValue(for: bpm)
            item["max"] = series.maximumQuantity.doubleValue(for: bpm)
        }
        if let raw = sample.metadata?[HKMetadataKeyHeartRateMotionContext] as? NSNumber {
            switch HKHeartRateMotionContext(rawValue: raw.intValue) {
            case .sedentary: item["motionContext"] = "sedentary"
            case .active: item["motionContext"] = "active"
            default: break
            }
        }
        return item
    }

    /// A stable name for each sleep analysis value: in bed, awake, or one
    /// of the asleep stages (`asleep` when the source does not stage it).
    private static func sleepStageName(_ value: Int) -> String {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: return "inBed"
        case .awake: return "awake"
        case .asleepCore: return "core"
        case .asleepDeep: return "deep"
        case .asleepREM: return "rem"
        default: return "asleep"
        }
    }

    /// Sleep between two instants, oldest first, as the sources wrote it:
    /// time in bed and every asleep or awake stretch, each with its stage
    /// and whether it counts as asleep, so a page can mark the night.
    func getSleepIntervals(startDate: Double?, endDate: Double?, completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion(.failure(CraftHealthError(message: "Sleep data is unavailable")))
            return
        }

        let end = endDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let start = startDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Calendar.current.date(byAdding: .day, value: -1, to: end)!
        // Any interval that overlaps the range, so a night that began
        // before it still counts.
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let oldestFirst = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let query = HKSampleQuery(sampleType: sleepType, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: [oldestFirst]) { [weak self] _, samples, error in
            if let error = error, (error as? HKError)?.code != .errorNoData {
                completion(.failure(CraftHealthError(message: error.localizedDescription)))
                return
            }

            let notAsleep: Set<Int> = [HKCategoryValueSleepAnalysis.inBed.rawValue, HKCategoryValueSleepAnalysis.awake.rawValue]
            let rows: [[String: Any]] = (samples as? [HKCategorySample] ?? []).map { sample in
                var item: [String: Any] = [
                    "startDate": sample.startDate.timeIntervalSince1970 * 1000,
                    "endDate": sample.endDate.timeIntervalSince1970 * 1000,
                    "stage": Self.sleepStageName(sample.value),
                    "asleep": !notAsleep.contains(sample.value),
                    "sourceName": sample.sourceRevision.source.name,
                ]
                if let device = sample.device?.name { item["deviceName"] = device }
                return item
            }
            completion(.success(rows))
        }
        healthStore.execute(query)
    }

    /// Saves a mindful session (Mindful Minutes in the Health app): a
    /// meditation or breathing session that ran from `startDate` to
    /// `endDate`, epoch milliseconds. `id` is the app's own id for it, kept
    /// as the sample's external UUID, so saving the same session twice (a
    /// retry, a second device) keeps the first sample instead of adding
    /// another: the answer then says `existing: true`.
    func saveMindfulSession(body: [String: Any], completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }
        guard let mindfulType = HKObjectType.categoryType(forIdentifier: .mindfulSession) else {
            completion(.failure(CraftHealthError(message: "Mindful sessions are unavailable")))
            return
        }
        guard let id = body["id"] as? String, !id.isEmpty, id.count <= 128,
              let startValue = body["startDate"] as? Double,
              let endValue = body["endDate"] as? Double,
              endValue > startValue,
              endValue - startValue <= 24 * 3600 * 1000 else {
            completion(.failure(CraftHealthError(message: "A valid id, startDate and endDate (at most a day apart) are required", code: "INVALID_ARGUMENT")))
            return
        }

        let start = Date(timeIntervalSince1970: startValue / 1000)
        let end = Date(timeIntervalSince1970: endValue / 1000)
        // Only this app's own samples can be the same session.
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeyExternalUUID, allowedValues: [id]),
            HKQuery.predicateForObjects(from: HKSource.default()),
        ])
        let lookup = HKSampleQuery(sampleType: mindfulType, predicate: predicate, limit: 1, sortDescriptors: nil) { _, samples, _ in
            if let kept = samples?.first {
                completion(.success(["id": kept.uuid.uuidString, "externalId": id, "existing": true]))
                return
            }
            let sample = HKCategorySample(
                type: mindfulType,
                value: HKCategoryValue.notApplicable.rawValue,
                start: start,
                end: end,
                metadata: [HKMetadataKeyExternalUUID: id]
            )
            healthStore.save(sample) { success, error in
                if success {
                    completion(.success(["id": sample.uuid.uuidString, "externalId": id, "existing": false]))
                } else {
                    completion(.failure(CraftHealthError(message: error?.localizedDescription ?? "Mindful session could not be saved")))
                }
            }
        }
        healthStore.execute(lookup)
    }

    /// Mindful sessions between two instants, oldest first, from every app
    /// that writes them (the Mindfulness app, Calm, this one). Each says
    /// whether this app wrote it (`ownApp`) and carries the external id it
    /// was saved with, so a page can tell its own sessions from the rest.
    func getMindfulSessions(startDate: Double?, endDate: Double?, limit: Int?, completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let healthStore = healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }
        guard let mindfulType = HKObjectType.categoryType(forIdentifier: .mindfulSession) else {
            completion(.failure(CraftHealthError(message: "Mindful sessions are unavailable")))
            return
        }

        let end = endDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Date()
        let start = startDate.map { Date(timeIntervalSince1970: $0 / 1000) } ?? Calendar.current.date(byAdding: .day, value: -30, to: end)!
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let oldestFirst = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let cap = max(1, min(limit ?? 1000, 5000))
        let ownBundle = Bundle.main.bundleIdentifier

        let query = HKSampleQuery(sampleType: mindfulType, predicate: predicate, limit: cap, sortDescriptors: [oldestFirst]) { _, samples, error in
            if let error = error, (error as? HKError)?.code != .errorNoData {
                completion(.failure(CraftHealthError(message: error.localizedDescription)))
                return
            }
            let rows: [[String: Any]] = (samples ?? []).map { sample in
                let source = sample.sourceRevision.source
                var item: [String: Any] = [
                    "id": sample.uuid.uuidString,
                    "startDate": sample.startDate.timeIntervalSince1970 * 1000,
                    "endDate": sample.endDate.timeIntervalSince1970 * 1000,
                    "durationSeconds": sample.endDate.timeIntervalSince(sample.startDate),
                    "sourceName": source.name,
                    "sourceBundleId": source.bundleIdentifier,
                    "ownApp": ownBundle != nil && source.bundleIdentifier == ownBundle,
                ]
                if let external = sample.metadata?[HKMetadataKeyExternalUUID] as? String { item["externalId"] = external }
                if let device = sample.device?.name { item["deviceName"] = device }
                return item
            }
            completion(.success(rows))
        }
        healthStore.execute(query)
    }

    // MARK: Live workout sessions

    /// Starts an OS-owned workout session. HealthKit's live builder was
    /// introduced for iOS 26; older systems receive a clear unsupported
    /// result instead of silently recording a post-hoc workout.
    func startWorkout(body: [String: Any], completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard let type = body["type"] as? String, !type.isEmpty else {
            completion(.failure(CraftHealthError(message: "startWorkout needs a workout type", code: "INVALID_ARGUMENT")))
            return
        }
        guard healthStore != nil else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }
        guard liveWorkoutID == nil else {
            completion(.failure(CraftHealthError(message: "A live workout is already running", code: "WORKOUT_IN_PROGRESS")))
            return
        }
        guard #available(iOS 26.0, *) else {
            completion(.failure(CraftHealthError(message: "Live workouts require iOS 26 or later", code: "UNSUPPORTED")))
            return
        }
        startWorkout26(type: type, location: body["location"] as? String, completion: completion)
    }

    @available(iOS 26.0, *)
    private func startWorkout26(type: String, location: String?, completion: @escaping Completion) {
        guard let healthStore else {
            completion(.failure(CraftHealthError(message: "HealthKit not available")))
            return
        }
        guard let activity = Self.workoutActivity(type) else {
            completion(.failure(CraftHealthError(message: "Unsupported workout type", code: "INVALID_ARGUMENT")))
            return
        }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activity
        switch location {
        case "indoor": configuration.locationType = .indoor
        case "outdoor": configuration.locationType = .outdoor
        case nil, "unknown": configuration.locationType = .unknown
        default:
            completion(.failure(CraftHealthError(message: "location must be indoor, outdoor, or unknown", code: "INVALID_ARGUMENT")))
            return
        }
        do {
            let session = try HKWorkoutSession(healthStore: healthStore, configuration: configuration)
            let builder = session.associatedWorkoutBuilder()
            let id = UUID().uuidString.lowercased()
            let delegate = CraftHealthWorkoutDelegate(id: { id }) { [weak self] detail in
                onMain {
                    guard let self, self.liveWorkoutID == id else { return }
                    self.sendWorkout(detail)
                }
            }
            let metricsDelegate = CraftHealthWorkoutBuilderDelegate(owner: self)
            session.delegate = delegate
            builder.delegate = metricsDelegate
            builder.shouldCollectWorkoutEvents = true
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: configuration)
            liveWorkoutSession = session
            liveWorkoutBuilder = builder
            liveWorkoutDelegate = delegate
            liveWorkoutBuilderDelegate = metricsDelegate
            liveWorkoutID = id
            liveWorkoutType = type
            liveWorkoutStart = Date()
            let start = liveWorkoutStart!
            session.startActivity(with: start)
            builder.beginCollection(withStart: start) { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    guard self.liveWorkoutID == id else {
                        completion(.failure(CraftHealthError(message: "Live workout was discarded while starting", code: "WORKOUT_CANCELLED")))
                        return
                    }
                    guard success else {
                        self.clearLiveWorkout()
                        completion(.failure(CraftHealthError(message: error?.localizedDescription ?? "Live workout could not start")))
                        return
                    }
                    completion(.success(["id": id, "type": type, "startDate": start.timeIntervalSince1970 * 1000]))
                }
            }
        } catch {
            clearLiveWorkout()
            completion(.failure(CraftHealthError(message: error.localizedDescription, code: "INVALID_ARGUMENT")))
        }
    }

    func pauseWorkout(completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard #available(iOS 26.0, *), let session = liveWorkoutSession as? HKWorkoutSession else {
            completion(.failure(CraftHealthError(message: "No live workout is running", code: "NO_WORKOUT")))
            return
        }
        session.pause()
        completion(.success(true))
    }

    func resumeWorkout(completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard #available(iOS 26.0, *), let session = liveWorkoutSession as? HKWorkoutSession else {
            completion(.failure(CraftHealthError(message: "No live workout is running", code: "NO_WORKOUT")))
            return
        }
        session.resume()
        completion(.success(true))
    }

    func endWorkout(completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard !liveWorkoutEnding else {
            completion(.failure(CraftHealthError(message: "Live workout is already being saved", code: "WORKOUT_ENDING")))
            return
        }
        guard #available(iOS 26.0, *), let session = liveWorkoutSession as? HKWorkoutSession, let builder = liveWorkoutBuilder as? HKLiveWorkoutBuilder, let id = liveWorkoutID else {
            completion(.failure(CraftHealthError(message: "No live workout is running", code: "NO_WORKOUT")))
            return
        }
        let end = Date()
        liveWorkoutEnding = true
        session.end()
        builder.endCollection(withEnd: end) { [weak self] success, error in
            guard let self else { return }
            guard success else {
                DispatchQueue.main.async {
                    self.liveWorkoutEnding = false
                    completion(.failure(CraftHealthError(message: error?.localizedDescription ?? "Live workout could not end")))
                }
                return
            }
            builder.finishWorkout { [weak self] workout, finishError in
                DispatchQueue.main.async {
                    guard let self else { return }
                    defer { self.clearLiveWorkout() }
                    guard let workout else {
                        completion(.failure(CraftHealthError(message: finishError?.localizedDescription ?? "Live workout could not be saved")))
                        return
                    }
                    completion(.success([
                        "id": id,
                        "workoutId": workout.uuid.uuidString,
                        "endDate": end.timeIntervalSince1970 * 1000,
                        "durationSeconds": workout.duration,
                    ]))
                }
            }
        }
    }

    /// Stops collection without calling finishWorkout (which saves a workout).
    /// It does not delete health samples already persisted by HealthKit.
    func discardWorkout(completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        guard !liveWorkoutEnding else {
            completion(.failure(CraftHealthError(message: "Live workout is already being saved", code: "WORKOUT_ENDING")))
            return
        }
        guard let id = liveWorkoutID, discardLiveWorkout(expectedID: id) else {
            completion(.failure(CraftHealthError(message: "No live workout is running", code: "NO_WORKOUT")))
            return
        }
        completion(.success(true))
    }

    /// Only the Live Activity that started this runtime can release it. HQ
    /// persists its own final result, so collecting here must not duplicate it.
    func discardActivityWorkout(expectedID: String) {
        _ = discardLiveWorkout(expectedID: expectedID)
    }

    private func discardLiveWorkout(expectedID: String) -> Bool {
        guard #available(iOS 26.0, *), !liveWorkoutEnding, liveWorkoutID == expectedID,
              let session = liveWorkoutSession as? HKWorkoutSession,
              let builder = liveWorkoutBuilder as? HKLiveWorkoutBuilder else { return false }
        session.end()
        builder.discardWorkout()
        clearLiveWorkout()
        return true
    }

    private func clearLiveWorkout() {
        liveWorkoutEnding = false
        liveWorkoutSession = nil
        liveWorkoutBuilder = nil
        liveWorkoutDelegate = nil
        liveWorkoutBuilderDelegate = nil
        liveWorkoutID = nil
        liveWorkoutType = nil
        liveWorkoutStart = nil
    }

    @available(iOS 26.0, *)
    fileprivate func emitLiveWorkoutMetrics(_ builder: HKLiveWorkoutBuilder) {
        guard let id = liveWorkoutID, builder === liveWorkoutBuilder else { return }
        var detail: [String: Any] = ["id": id, "event": "metrics", "date": Date().timeIntervalSince1970 * 1000]
        let bpm = HKUnit.count().unitDivided(by: .minute())
        if let type = HKQuantityType.quantityType(forIdentifier: .heartRate),
           let value = builder.statistics(for: type)?.mostRecentQuantity()?.doubleValue(for: bpm), value.isFinite {
            detail["heartRateBpm"] = value
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
           let value = builder.statistics(for: type)?.sumQuantity()?.doubleValue(for: .kilocalorie()), value.isFinite {
            detail["activeEnergyCalories"] = value
        }
        if let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
           let value = builder.statistics(for: type)?.sumQuantity()?.doubleValue(for: .meter()), value.isFinite {
            detail["distanceMeters"] = value
        }
        onMain { [weak self] in
            guard let self, self.liveWorkoutID == id else { return }
            self.sendWorkout(detail)
        }
    }

    private static func workoutActivity(_ type: String) -> HKWorkoutActivityType? {
        switch type {
        case "running": return .running
        case "walking": return .walking
        case "hiking": return .hiking
        case "cycling": return .cycling
        case "swimming": return .swimming
        case "rowing": return .rowing
        case "elliptical": return .elliptical
        case "strength": return .traditionalStrengthTraining
        case "hiit": return .highIntensityIntervalTraining
        case "flexibility": return .flexibility
        case "yoga": return .yoga
        case "other": return .other
        default: return nil
        }
    }

    private func sendWorkout(_ detail: [String: Any]) {
        if workoutSink?(detail) != true { CraftWebServices.forward("craftHealthWorkout", data: detail) }
    }

    // MARK: Heart rate as it arrives

    /// The web view's coordinator, which sends `craftHealthHeartRate` to the
    /// page and every native screen. False (or unset, in an app without a web
    /// view) and the event goes to the native screens alone.
    var pageSink: (([String: Any]) -> Bool)?

    /// Live workout lifecycle events use a separate page event so existing
    /// heart-rate listeners remain unchanged. When no page owns the event,
    /// CraftWebServices forwards it to native screens.
    var workoutSink: (([String: Any]) -> Bool)?

    // Stored as object references because the generated app still supports
    // iOS 16.2; concrete HealthKit types are only touched behind the iOS 26
    // availability checks below.
    private var liveWorkoutSession: AnyObject?
    private var liveWorkoutEnding = false
    private var liveWorkoutBuilder: AnyObject?
    private var liveWorkoutDelegate: AnyObject?
    private var liveWorkoutBuilderDelegate: AnyObject?
    private var liveWorkoutID: String?
    private var liveWorkoutType: String?
    private var liveWorkoutStart: Date?

    /// The one running stream: an anchored query that hears every heart-rate
    /// sample HealthKit receives after it starts.
    private var heartRateQuery: HKAnchoredObjectQuery?
    /// Samples already sent, so a batch HealthKit repeats is not sent twice.
    private var heartRateSent: Set<UUID> = []
    /// Bumped by every start and stop, so a stopped stream's late batch is dropped.
    private var heartRateStream = 0
    #if targetEnvironment(simulator)
    private var simulatedHeartRateTimer: Timer?
    #endif

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Heart rate as Apple Health receives it, for as long as it runs: every
    /// sample that starts at or after `since` (epoch ms; two minutes ago by
    /// default), first what is there already, then each batch as the watch
    /// syncs it, as `craftHealthHeartRate` events (`{samples}`, oldest first,
    /// each sample once, in getHeartRateSamples' shape). One stream at a
    /// time: starting again replaces the running one. Reads under the
    /// `heartRate` grant. Answers true once the samples already there are
    /// sent.
    ///
    /// Simulator builds with the `CraftFakeHealthHeartRate` default
    /// (`xcrun simctl spawn booted defaults write <bundle id>
    /// CraftFakeHealthHeartRate -bool YES`) skip HealthKit and send a made-up
    /// watch reading every five seconds instead.
    func startHeartRateUpdates(since: Double?, completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        let start = Date(timeIntervalSince1970: (since ?? Date().timeIntervalSince1970 * 1000 - 120_000) / 1000)
        onMain { [self] in
            stopHeartRateStream()
            let stream = heartRateStream

            #if targetEnvironment(simulator)
            if UserDefaults.standard.bool(forKey: "CraftFakeHealthHeartRate") {
                startSimulatedHeartRate(stream: stream)
                completion(.success(true))
                return
            }
            #endif

            guard let healthStore = healthStore else {
                completion(.failure(CraftHealthError(message: "HealthKit not available")))
                return
            }
            guard let heartType = HKQuantityType.quantityType(forIdentifier: .heartRate) else {
                completion(.failure(CraftHealthError(message: "Heart rate is unavailable")))
                return
            }

            let predicate = HKQuery.predicateForSamples(withStart: start, end: nil, options: .strictStartDate)
            let query = HKAnchoredObjectQuery(type: heartType, predicate: predicate, anchor: nil, limit: HKObjectQueryNoLimit) { [weak self] _, samples, _, _, error in
                let rows = (samples as? [HKQuantitySample] ?? []).map { ($0.uuid, Self.heartRateRow($0)) }
                DispatchQueue.main.async {
                    // Stopped or replaced before its first batch: it did start.
                    guard let self, self.heartRateStream == stream else { return completion(.success(true)) }
                    if let error = error, (error as? HKError)?.code != .errorNoData {
                        self.stopHeartRateStream()
                        return completion(.failure(CraftHealthError(message: error.localizedDescription)))
                    }
                    self.sendHeartRate(rows)
                    completion(.success(true))
                }
            }
            query.updateHandler = { [weak self] _, samples, _, _, error in
                if let error = error {
                    NSLog("[craft] Apple Health heart rate: %@", error.localizedDescription)
                    return
                }
                let rows = (samples as? [HKQuantitySample] ?? []).map { ($0.uuid, Self.heartRateRow($0)) }
                DispatchQueue.main.async {
                    guard let self, self.heartRateStream == stream else { return }
                    self.sendHeartRate(rows)
                }
            }
            heartRateQuery = query
            healthStore.execute(query)
        }
    }

    /// Stops the stream; true whether or not one was running.
    func stopHeartRateUpdates(completion rawCompletion: @escaping Completion) {
        let completion = completeOnMain(rawCompletion)
        onMain { [self] in
            stopHeartRateStream()
            completion(.success(true))
        }
    }

    /// Main only.
    private func stopHeartRateStream() {
        heartRateStream += 1
        if let query = heartRateQuery { healthStore?.stop(query) }
        heartRateQuery = nil
        heartRateSent.removeAll()
        #if targetEnvironment(simulator)
        simulatedHeartRateTimer?.invalidate()
        simulatedHeartRateTimer = nil
        #endif
    }

    /// Sends the samples not sent before, oldest first; nothing when none are new. Main only.
    private func sendHeartRate(_ rows: [(UUID, [String: Any])]) {
        let fresh = rows
            .filter { heartRateSent.insert($0.0).inserted }
            .map { $0.1 }
            .sorted { ($0["startDate"] as? Double ?? 0) < ($1["startDate"] as? Double ?? 0) }
        guard !fresh.isEmpty else { return }
        let detail: [String: Any] = ["samples": fresh]
        if pageSink?(detail) != true { CraftWebServices.forward("craftHealthHeartRate", data: detail) }
    }

    /// The simulator's watch: someone settling into slow breathing, about 72
    /// at first and easing toward 60 over a few minutes, with a small wobble.
    static func simulatedHeartRate(elapsed: TimeInterval) -> Double {
        (60 + 12 * exp(-elapsed / 150) + 1.5 * sin(elapsed / 9)).rounded()
    }

    #if targetEnvironment(simulator)
    /// One made-up watch reading now and every five seconds after. Main only.
    private func startSimulatedHeartRate(stream: Int) {
        let began = Date()
        let send: () -> Void = { [weak self] in
            guard let self, self.heartRateStream == stream else { return }
            let now = Date().timeIntervalSince1970 * 1000
            self.sendHeartRate([(UUID(), [
                "bpm": Self.simulatedHeartRate(elapsed: Date().timeIntervalSince(began)),
                "startDate": now,
                "endDate": now,
                "sourceName": "Apple Watch (simulated)",
                "deviceName": "Apple Watch",
                "motionContext": "sedentary",
            ])])
        }
        send()
        simulatedHeartRateTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in send() }
    }
    #endif
}
