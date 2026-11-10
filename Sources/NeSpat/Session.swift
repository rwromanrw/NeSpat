import Foundation

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

    /// Приложение-владелец сессии живо?
    static func ownerAlive(_ s: Session) -> Bool {
        guard s.owned, s.pid > 0 else { return false }
        return kill(s.pid, 0) == 0
    }
}
