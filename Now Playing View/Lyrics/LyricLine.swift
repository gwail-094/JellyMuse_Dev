import Foundation

public struct LyricLine: Identifiable, Hashable {
    public let id = UUID()
    public let time: TimeInterval
    public let text: String

    public init(time: TimeInterval, text: String) {
        self.time = time
        self.text = text
    }
}
