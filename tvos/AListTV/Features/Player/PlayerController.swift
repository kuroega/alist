import Foundation

enum PlayerEvent: Equatable, Sendable {
    case failed(message: String)
    case paused
}

@MainActor
protocol PlayerControlling: AnyObject {
    var events: AsyncStream<PlayerEvent> { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }

    func replaceCurrentItem(url: URL)
    func play()
    func pause()
    func seek(to seconds: TimeInterval) async
}

