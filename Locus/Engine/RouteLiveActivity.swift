import ActivityKit
import Foundation

/// Shows the arrival time in the Dynamic Island and on the Lock Screen.
@MainActor
final class RouteLiveActivity {
    private var activity: Activity<RouteActivityAttributes>?
    private var lastDestination: String?
    private var lastUpdate = Date.distantPast
    private let minimumUpdateGap: TimeInterval = 10

    func update(destination: String, remaining: TimeInterval) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let now = Date()
        guard destination != lastDestination || now.timeIntervalSince(lastUpdate) >= minimumUpdateGap else { return }
        lastDestination = destination
        lastUpdate = now

        let state = RouteActivityAttributes.ContentState(
            destination: destination,
            arrival: now.addingTimeInterval(max(remaining, 1))
        )
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity {
            Task { await activity.update(content) }
        } else {
            activity = try? Activity.request(
                attributes: RouteActivityAttributes(),
                content: content,
                pushType: nil
            )
        }
    }

    func end() {
        guard let current = activity else { return }
        activity = nil
        lastDestination = nil
        lastUpdate = .distantPast
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }
}
