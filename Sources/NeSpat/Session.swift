import Foundation
import Darwin

// MARK: - Состояние сессии (один файл)

struct Session: Codable, Equatable {
    /// Сессию включило это приложение (флаг наш, а не чужой).
    var owned: Bool = false
    /// До какого момента держать (nil — без ограничения).
    var until: Date?
    /// Причина последнего автоотключения.
    var lastReason: String?
    /// PID приложения, включившего сессию.
    var pid: Int32 = 0

    /// Когда крышку закрыли при нашей сессии (идёт замер «под крышкой»).
    var lidClosedAt: Date?
    /// Последний тик «ещё не спал» при закрытой крышке.
    var lidHeartbeatAt: Date?
    /// Итог последнего замера: сколько секунд реально не спал под крышкой.
    var lastLidAwakeSeconds: TimeInterval?
}

enum SessionStore {
    static func load() -> Session {
        guard let data = try? Data(contentsOf: Paths.sessionFile),
              let s = try? JSONDecoder().decode(Session.self, from: data) else { return Session() }
        return s
    }

    static func save(_ s: Session) {
        Paths.ensureDir(Paths.supportDir)
        if let data = try? JSONEncoder().encode(s) {
            try? data.write(to: Paths.sessionFile, options: .atomic)
        }
    }

    /// Приложение-владелец сессии живо и это именно NeSpat (не чужой PID после переиспользования).
    static func ownerAlive(_ s: Session) -> Bool {
        guard s.owned, s.pid > 0 else { return false }
        guard kill(s.pid, 0) == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(s.pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.contains("NeSpat")
    }
}
