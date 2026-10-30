import Foundation

/// One completed child session, synced child → admin (T4.6, LLD sync).
/// Built on the merged T1.6 `Decision` schema unchanged: the session's
/// decisions are carried verbatim, never re-shaped.
public struct SessionLog: Codable, Equatable, Sendable {
    public var sessionId: String
    public var startedAt: Date
    public var endedAt: Date
    public var decisions: [Decision]
    /// Child's policy version in force for this session.
    public var policyVersion: Int
    public init(sessionId: String, startedAt: Date, endedAt: Date,
                decisions: [Decision], policyVersion: Int) {
        self.sessionId = sessionId; self.startedAt = startedAt
        self.endedAt = endedAt; self.decisions = decisions
        self.policyVersion = policyVersion
    }
    /// Builds a log from the T1.6 DecisionLogger for one session.
    public static func make(sessionId: String, startedAt: Date, endedAt: Date,
                            logger: DecisionLogger, policyVersion: Int) -> SessionLog {
        SessionLog(sessionId: sessionId, startedAt: startedAt, endedAt: endedAt,
                   decisions: logger.decisions(for: sessionId), policyVersion: policyVersion)
    }
}

public enum SessionLogCodec {
    public static func encode(_ log: SessionLog) throws -> Data { try encodeValue(log) }
    public static func encode(_ logs: [SessionLog]) throws -> Data { try encodeValue(logs) }
    private static func encodeValue(_ v: some Encodable) throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .deferredToDate
        e.outputFormatting = [.sortedKeys]; return try e.encode(v)
    }
    public static func decode(_ data: Data) throws -> SessionLog {
        let d = JSONDecoder(); d.dateDecodingStrategy = .deferredToDate
        return try d.decode(SessionLog.self, from: data)
    }
    public static func decodeList(_ data: Data) throws -> [SessionLog] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .deferredToDate
        return try d.decode([SessionLog].self, from: data)
    }
}
