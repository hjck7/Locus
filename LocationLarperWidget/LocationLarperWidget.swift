import ActivityKit
import SwiftUI
import WidgetKit

@main
struct LocationLarperWidgetBundle: WidgetBundle {
    var body: some Widget {
        RouteActivityWidget()
    }
}

struct RouteActivityWidget: Widget {
    private let tint = Color(red: 0.36, green: 0.36, blue: 0.96)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RouteActivityAttributes.self) { context in
            arrivalText(context.state)
                .padding(16)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    arrivalText(context.state)
                }
            } compactLeading: {
                Image(systemName: "location.fill").foregroundStyle(tint)
            } compactTrailing: {
                countdown(context.state)
                    .frame(width: 46)
                    .foregroundStyle(tint)
            } minimal: {
                Image(systemName: "location.fill").foregroundStyle(tint)
            }
        }
    }

    private func arrivalText(_ state: RouteActivityAttributes.ContentState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text("Arriving in")
                countdown(state).fontWeight(.bold)
            }
            Text("at \(state.destination)")
                .font(.headline)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countdown(_ state: RouteActivityAttributes.ContentState) -> some View {
        let now = Date()
        return Text(timerInterval: now...max(state.arrival, now), countsDown: true)
            .monospacedDigit()
    }
}
