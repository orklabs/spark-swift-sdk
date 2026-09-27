import Foundation
import GRPCCore
import Synchronization

/// The operators' clock as this device estimates it, like the reference SDK's `ServerTimeSync`.
/// Every successful operator answer carries its `date` (whole seconds) and how long it took to
/// process (`x-processing-time-ms`); half the remaining round trip is added to the date, and the
/// estimate then advances on the monotonic clock, so a device clock that is wrong — or changes —
/// does not move it. Until the first answer the device clock is used.
final class ServerClock: Sendable {
    private struct Sample {
        let serverTime: Date
        let at: ContinuousClock.Instant
    }
    private let sample = Mutex<Sample?>(nil)

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        // Go's time.RFC1123, which the operators send: "Mon, 02 Jan 2006 15:04:05 UTC".
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    var isSynced: Bool {
        sample.withLock { $0 != nil }
    }

    /// The operators' current time: the latest estimate advanced by the monotonic clock, or the
    /// device clock before any answer.
    func now() -> Date {
        guard let sample = sample.withLock({ $0 }) else { return Date() }
        return sample.serverTime.addingTimeInterval(Self.seconds(ContinuousClock.now - sample.at))
    }

    /// Records one answer: `date` and `processingTime` from its headers, sent at `sent` and
    /// answered at `received`. A header that does not parse is ignored.
    func record(date: String, processingTime: String, sent: ContinuousClock.Instant, received: ContinuousClock.Instant) {
        guard let serverDate = Self.dateFormatter.date(from: date),
              let processingMs = Double(processingTime), processingMs >= 0 else { return }
        let roundTrip = max(0, Self.seconds(received - sent) - processingMs / 1000)
        let estimate = Sample(serverTime: serverDate.addingTimeInterval(roundTrip / 2), at: received)
        sample.withLock { $0 = estimate }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// Feeds `ServerClock` from the headers of every operator answer. Innermost interceptor, so the
/// measured round trip excludes the authentication a call may wait for first.
struct ServerTimeInterceptor: ClientInterceptor {
    let clock: ServerClock

    func intercept<Input: Sendable, Output: Sendable>(
        request: StreamingClientRequest<Input>,
        context: ClientContext,
        next: (
            _ request: StreamingClientRequest<Input>,
            _ context: ClientContext
        ) async throws -> StreamingClientResponse<Output>
    ) async throws -> StreamingClientResponse<Output> {
        let sent = ContinuousClock.now
        let response = try await next(request, context)
        if case .success(let contents) = response.accepted,
           let date = contents.metadata[stringValues: "date"].first(where: { _ in true }),
           let processing = contents.metadata[stringValues: "x-processing-time-ms"].first(where: { _ in true }) {
            clock.record(date: date, processingTime: processing, sent: sent, received: .now)
        }
        return response
    }
}
