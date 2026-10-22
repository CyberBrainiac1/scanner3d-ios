import Foundation

/// PC -> phone `capture.stop` (Decision S9) as a pure state machine. The phone's capture is the source of truth,
/// so it never stops silently on a PC request: it answers within 5 s with `declined_user_confirm`, shows a
/// confirmation sheet, and only if the user confirms it stops and sends `session.stop {reason: pc_request}`.
///
/// TODO-RELEASE: bound to the 2026-10-21 M2-C2 DRAFT schemas (capture.stop.request/response, session.stop reason
/// `pc_request`). Reconcile names/enums with the "contracts/stream RELEASED" hash list. `session.end` has no
/// `pc_request` reason in the draft, so session_end.json records `user` (the user confirmed the stop).
public struct CaptureStopFlow: Sendable, Equatable {
    public static let messageType = "capture.stop"            // TODO-RELEASE
    public static let resultAccepted = "accepted"              // TODO-RELEASE (never sent by this app)
    public static let resultDeclinedUserConfirm = "declined_user_confirm" // TODO-RELEASE
    public static let stopReason = "pc_request"                // TODO-RELEASE (session.stop reason)

    public struct Request: Sendable, Equatable, Identifiable {
        public let requestID: String
        public let sessionID: UUID
        public let reason: String      // user_stop | storage | fault
        public let detail: String?
        public var id: String { requestID }
    }

    /// What the socket adapter must send right now (exactly one response per request).
    public enum Reply: Sendable, Equatable {
        case response(replyTo: String, body: JSONValue)
        case errorResponse(replyTo: String, code: String, message: String)
    }

    /// What the capture layer must do.
    public enum Effect: Sendable, Equatable {
        case none
        case showConfirmation(Request)
        case stopCapture(sessionID: UUID, sessionStopReason: String)
        case dismissConfirmation
    }

    public enum Phase: Sendable, Equatable {
        case idle
        case asking(Request)
        case stopping(Request)
    }

    public private(set) var phase: Phase = .idle

    public init() {}

    public mutating func receive(requestID: String, body: CaptureStopRequestBody,
                                 recordingSession: UUID?) -> (Reply, Effect) {
        guard let current = recordingSession else {
            return (.errorResponse(replyTo: requestID, code: "session_not_active",
                                   message: "The phone is not recording."), .none)
        }
        guard current == body.sessionID else {
            return (.errorResponse(replyTo: requestID, code: "unknown_session",
                                   message: "The phone is recording a different session."), .none)
        }
        let request = Request(requestID: requestID, sessionID: body.sessionID, reason: body.reason,
                              detail: body.detail.map { String($0.prefix(200)) })
        let reply = Reply.response(replyTo: requestID, body: .object([
            "session_id": .uuid(body.sessionID), "result": .string(CaptureStopFlow.resultDeclinedUserConfirm)]))
        switch phase {
        case .idle:
            phase = .asking(request)
            return (reply, .showConfirmation(request))
        case .asking:
            // A repeated request keeps the one sheet; answer it the same way.
            phase = .asking(request)
            return (reply, .none)
        case .stopping:
            return (reply, .none)
        }
    }

    public mutating func userConfirmed() -> Effect {
        guard case .asking(let request) = phase else { return .none }
        phase = .stopping(request)
        return .stopCapture(sessionID: request.sessionID, sessionStopReason: CaptureStopFlow.stopReason)
    }

    public mutating func userDeclined() -> Effect {
        guard case .asking = phase else { return .none }
        phase = .idle
        return .dismissConfirmation
    }

    /// The capture stopped for any reason (local Stop, thermal, ...): close the sheet.
    public mutating func captureEnded() -> Effect {
        let wasAsking: Bool
        if case .asking = phase { wasAsking = true } else { wasAsking = false }
        phase = .idle
        return wasAsking ? .dismissConfirmation : .none
    }
}
