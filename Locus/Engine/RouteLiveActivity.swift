import ActivityKit
import Foundation

/// Shows the arrival time in the Dynamic Island and on the Lock Screen.
@MainActor
final class RouteLiveActivity {
    private var activity: Activity<RouteActivityAttributes>?
    private var lastDestination: String?
    private var lastUpdate = Date.distantPast
    private let minimumUpdateGap: TimeInterval = 10

    /// Why the Dynamic Island can't work on this install, if there is a known reason.
    static var problem: String? {
        let widget = Bundle.main.builtInPlugInsURL?.appendingPathComponent("LocationLarperWidget.appex")
        guard let widget, FileManager.default.fileExists(atPath: widget.path) else {
            return "Die Widget-Erweiterung fehlt in der installierten App."
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return "Live-Aktivitäten sind für diese App in den iPhone-Einstellungen aus."
        }
        return nil
    }

    /// Returns a description when the activity could not be started.
    @discardableResult
    func update(destination: String, remaining: TimeInterval) -> String? {
        if let problem = Self.problem { return problem }
        let now = Date()
        guard destination != lastDestination || now.timeIntervalSince(lastUpdate) >= minimumUpdateGap else { return nil }
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
            do {
                activity = try Activity.request(
                    attributes: RouteActivityAttributes(),
                    content: content,
                    pushType: nil
                )
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    func end() {
        guard let current = activity else { return }
        activity = nil
        lastDestination = nil
        lastUpdate = .distantPast
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }
}
