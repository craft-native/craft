import ActivityKit
import Foundation
import HealthKit

/// ActivityKit belongs to the process, not a web view or a retained STX screen.
/// A stable application activityId reattaches after a screen or app restart.
enum CraftLiveActivities {
    private static var scheduled: [String: Task<Void, Never>] = [:]
    private static var watching: [String: Task<Void, Never>] = [:]
    private static var workoutOwner: (key: String, id: String)?
    private static var startingWorkout: String?

    static func perform(method: String, args: [Any], enabled: Bool, appName: String, healthEnabled: Bool = false, completion: @escaping (Result<Any, CraftNativeActionError>) -> Void) {
        guard enabled else {
            if method == "isAvailable" { completion(.success(false)); return }
            completion(.failure(CraftNativeActionError(code: "CAPABILITY_DISABLED", message: "Live Activities are disabled")))
            return
        }
        guard #available(iOS 16.2, *) else {
            if method == "isAvailable" { completion(.success(false)) }
            else { completion(.failure(CraftNativeActionError(code: "UNSUPPORTED", message: "Live Activities require iOS 16.2"))) }
            return
        }
        Task { @MainActor in
            do {
                let activities = Activity<CraftActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
                switch method {
                case "isAvailable": completion(.success(ActivityAuthorizationInfo().areActivitiesEnabled))
                case "list": completion(.success(activities.map { ["id": $0.id, "activityId": $0.attributes.activityId, "title": $0.attributes.title] }))
                case "start":
                    guard ActivityAuthorizationInfo().areActivitiesEnabled else {
                        throw CraftNativeActionError(code: "NOT_ALLOWED", message: "Live Activities are turned off in Settings")
                    }
                    let body = args.first as? [String: Any] ?? [:]
                    guard let key = body["activityId"] as? String, !key.isEmpty,
                          let title = body["title"] as? String, !title.isEmpty else {
                        throw CraftNativeActionError(code: "INVALID_ARGUMENT", message: "A Live Activity needs activityId and title")
                    }
                    let state = content(body)
                    if let existing = activities.first(where: { $0.attributes.activityId == key }) {
                        await existing.update(ActivityContent(state: state, staleDate: staleDate(body)))
                        watch(existing)
                        schedule(existing, plan: plan(body))
                        startWorkout(existing, body: body, enabled: healthEnabled)
                        completion(.success(["id": existing.id]))
                        return
                    }
                    let attributes = CraftActivityAttributes(activityId: key, title: String(title.prefix(160)), symbol: body["symbol"] as? String, deepLink: safeURL(body["deepLink"] as? String), tint: body["tint"] as? String)
                    let activity = try Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate(body)), pushType: nil)
                    watch(activity)
                    schedule(activity, plan: plan(body))
                    startWorkout(activity, body: body, enabled: healthEnabled)
                    completion(.success(["id": activity.id]))
                case "update", "end":
                    let id = args.first as? String
                    let activity = id == nil ? activities.first : activities.first(where: { $0.id == id })
                    guard let activity else {
                        if method == "end" { completion(.success(["ended": false])); return }
                        throw CraftNativeActionError(code: "NOT_FOUND", message: "No matching Live Activity is running")
                    }
                    let body = args.count > 1 ? args[1] as? [String: Any] ?? [:] : [:]
                    let previous = activity.content.state
                    let state = content(body, previous: previous)
                    if method == "end" {
                        watching.removeValue(forKey: activity.id)?.cancel()
                        scheduled.removeValue(forKey: activity.id)?.cancel()
                        stopWorkout(activity.attributes.activityId)
                        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .immediate)
                        completion(.success(["ended": true]))
                    } else {
                        await activity.update(ActivityContent(state: state, staleDate: staleDate(body)))
                        schedule(activity, plan: plan(body))
                        if let owner = workoutOwner, owner.key == activity.attributes.activityId, previous.paused != state.paused {
                            if state.paused == true { CraftHealth.shared.pauseWorkout { _ in } }
                            else { CraftHealth.shared.resumeWorkout { _ in } }
                        }
                        completion(.success(["updated": true]))
                    }
                default: throw CraftNativeActionError(code: "UNKNOWN_ACTION", message: "Unsupported Live Activities method")
                }
            } catch let error as CraftNativeActionError { completion(.failure(error)) }
            catch { completion(.failure(CraftNativeActionError(code: "ACTIVITY_ERROR", message: error.localizedDescription))) }
        }
    }

    /// Dismissing a Live Activity must release its own background workout
    /// runtime as well, even though it no longer appears in the active list.
    @available(iOS 16.2, *)
    @MainActor private static func watch(_ activity: Activity<CraftActivityAttributes>) {
        guard watching[activity.id] == nil else { return }
        watching[activity.id] = Task { @MainActor in
            for await state in activity.activityStateUpdates {
                if Task.isCancelled { return }
                if state == .ended || state == .dismissed {
                    scheduled.removeValue(forKey: activity.id)?.cancel()
                    stopWorkout(activity.attributes.activityId)
                    watching.removeValue(forKey: activity.id)
                    return
                }
            }
        }
    }

    /// The real HealthKit workout owns background execution on iOS 26. It
    /// collects while training; the caller's existing save path writes the
    /// final workout once. Never stop an unrelated HealthKit session.
    @available(iOS 16.2, *)
    @MainActor private static func startWorkout(_ activity: Activity<CraftActivityAttributes>, body: [String: Any], enabled: Bool) {
        guard enabled, #available(iOS 26.0, *), let type = body["workoutType"] as? String,
              workoutOwner == nil, startingWorkout == nil,
              HKHealthStore().authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return }
        let key = activity.attributes.activityId
        startingWorkout = key
        CraftHealth.shared.startWorkout(body: ["type": type]) { result in
            Task { @MainActor in
                startingWorkout = nil
                guard case .success(let value) = result, let value = value as? [String: Any], let id = value["id"] as? String else { return }
                guard activity.activityState == .active || activity.activityState == .stale else {
                    CraftHealth.shared.discardActivityWorkout(expectedID: id)
                    return
                }
                workoutOwner = (key, id)
                if activity.content.state.paused == true { CraftHealth.shared.pauseWorkout { _ in } }
            }
        }
    }

    @MainActor private static func stopWorkout(_ key: String) {
        guard let owner = workoutOwner, owner.key == key else { return }
        workoutOwner = nil
        CraftHealth.shared.discardActivityWorkout(expectedID: owner.id)
    }

    /// Step boundaries, independently of a retained screen or JS timer.
    /// HealthKit, GPS and BLE use their documented background execution;
    /// without permission iOS may suspend updates until the next app wake.
    @available(iOS 16.2, *)
    @MainActor private static func schedule(_ activity: Activity<CraftActivityAttributes>, plan: [CraftActivityAttributes.Transition]) {
        scheduled.removeValue(forKey: activity.id)?.cancel()
        guard activity.content.state.paused != true, !plan.isEmpty else { return }
        scheduled[activity.id] = Task { @MainActor in
            var timeline = CraftActivityTimeline(pending: plan)
            while !Task.isCancelled, let next = timeline.pending.first {
                let delay = max(0, next.at / 1000 - Date().timeIntervalSince1970)
                do { try await Task.sleep(nanoseconds: UInt64(min(delay, 86400) * 1_000_000_000)) }
                catch { return }
                guard !Task.isCancelled, activity.activityState == .active || activity.activityState == .stale else { return }
                var state = activity.content.state
                timeline.advance(&state, to: Date().timeIntervalSince1970 * 1000)
                if state.paused == true { stopWorkout(activity.attributes.activityId) }
                await activity.update(ActivityContent(state: state, staleDate: timeline.pending.last.map { Date(timeIntervalSince1970: $0.at / 1000 + ($0.duration ?? 8 * 3600) + 1) }))
            }
            scheduled.removeValue(forKey: activity.id)
        }
    }

    @available(iOS 16.1, *)
    private static func plan(_ body: [String: Any]) -> [CraftActivityAttributes.Transition] {
        let steps = (body["transitions"] as? [[String: Any]] ?? []).prefix(1000).compactMap { item -> CraftActivityAttributes.Transition? in
            guard let at = finite(item, "at"), let detail = item["detail"] as? String else { return nil }
            return .init(at: at, detail: String(detail.prefix(96)), duration: finite(item, "duration"))
        }.sorted { $0.at < $1.at }
        // An untimed exercise waits for the athlete. Never infer its completion.
        if let stop = steps.firstIndex(where: { $0.duration == nil || $0.duration == 0 }) { return Array(steps.prefix(stop + 1)) }
        return steps
    }

    private static func safeURL(_ value: String?) -> String? {
        guard let value, let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              !["javascript", "data", "file"].contains(scheme) else { return nil }
        return value
    }

    private static func finite(_ body: [String: Any], _ key: String, _ fallback: Double? = nil) -> Double? {
        guard body.keys.contains(key) else { return fallback }
        guard let number = craftNativeNumber(body[key]), number.doubleValue.isFinite else { return nil }
        return max(0, number.doubleValue)
    }

    private static func staleDate(_ body: [String: Any]) -> Date? {
        finite(body, "staleAt").map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    @available(iOS 16.2, *)
    private static func content(_ body: [String: Any], previous: CraftActivityAttributes.ContentState? = nil) -> CraftActivityAttributes.ContentState {
        CraftActivityAttributes.ContentState(
            status: String((body["status"] as? String ?? previous?.status ?? "").prefix(120)),
            distanceMeters: finite(body, "distanceMeters", previous?.distanceMeters) ?? 0,
            durationSeconds: finite(body, "durationSeconds", previous?.durationSeconds) ?? 0,
            progress: min(finite(body, "progress", previous?.progress) ?? 0, 1),
            staleStatus: body["staleStatus"] as? String ?? previous?.staleStatus,
            detail: body["detail"] as? String ?? previous?.detail,
            sessionStartedAt: finite(body, "sessionStartedAt", previous?.sessionStartedAt),
            timerStartedAt: finite(body, "timerStartedAt", previous?.timerStartedAt),
            timerEndsAt: finite(body, "timerEndsAt", previous?.timerEndsAt),
            paused: body["paused"] as? Bool ?? previous?.paused,
            remainingSeconds: finite(body, "remainingSeconds", previous?.remainingSeconds),
            heartRate: finite(body, "heartRate", previous?.heartRate),
            showsDistance: body["showsDistance"] as? Bool ?? previous?.showsDistance
        )
    }
}
