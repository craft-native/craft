import ActivityKit

@available(iOS 16.1, *)
struct CraftActivityAttributes: ActivityAttributes {
    struct Transition: Codable, Hashable {
        let at: Double
        let detail: String
        let duration: Double?
    }
    struct ContentState: Codable, Hashable {
        var status: String
        let distanceMeters: Double
        let durationSeconds: Double
        var progress: Double
        var staleStatus: String?
        var detail: String?
        /// Epoch milliseconds. SwiftUI advances these timers without app updates.
        var sessionStartedAt: Double?
        var timerStartedAt: Double?
        var timerEndsAt: Double?
        var paused: Bool?
        var remainingSeconds: Double?
        var heartRate: Double?
        var showsDistance: Bool?

    }

    let activityId: String
    let title: String
    var symbol: String?
    var deepLink: String?
    var tint: String?
}


/// The whole plan stays in the app process. Only ContentState crosses
/// ActivityKit's 4 KB payload boundary, regardless of the workout's length.
@available(iOS 16.1, *)
struct CraftActivityTimeline {
    var pending: [CraftActivityAttributes.Transition]

    mutating func advance(_ state: inout CraftActivityAttributes.ContentState, to milliseconds: Double) {
        let due = pending.prefix { $0.at <= milliseconds }
        guard let next = due.last else { return }
        pending.removeFirst(due.count)
        state.detail = next.detail
        state.timerStartedAt = next.duration == nil ? state.sessionStartedAt : next.at
        state.timerEndsAt = next.duration.map { next.at + $0 * 1000 }
        state.remainingSeconds = next.duration.map { max(0, $0 - (milliseconds - next.at) / 1000) }
        state.progress = 0
        if next.duration == 0 { state.status = next.detail; state.paused = true; state.progress = 1 }
    }
}
