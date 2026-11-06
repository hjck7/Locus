import ActivityKit
import Foundation

struct RouteActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var destination: String
        var arrival: Date
    }
}
