import Foundation

// MARK: - Пути

enum Paths {
    static var supportDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NeSpat", isDirectory: true)
    }

    static var sessionFile: URL { supportDir.appendingPathComponent("session.json") }

    static var logDir: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/NeSpat", isDirectory: true)
    }

    static var watchdogLog: URL { logDir.appendingPathComponent("watchdog.log") }

    static func ensureDir(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

// MARK: - Запуск процессов (без shell)

enum Proc {
    struct Result {
        let code: Int32
        let out: String
        let err: String
        var ok: Bool { code == 0 }
    }

    /// Запускает исполняемый файл с фиксированным argv. Без shell, без интерполяции.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return Result(code: -1, out: "", err: error.localizedDescription)
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Result(
            code: p.terminationStatus,
            out: String(data: outData, encoding: .utf8) ?? "",
            err: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    static func sudoPmset(disableSleep: Bool) -> Result {
        run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", disableSleep ? "1" : "0"])
    }

    static func displaysleepnow() -> Result {
        run("/usr/bin/pmset", ["displaysleepnow"])
    }
}

// MARK: - Форматирование (русский UI)

enum Fmt {
    static func percent(_ v: Double) -> String {
        "\(Int(v.rounded()))%"
    }

    static func gb(_ bytes: UInt64) -> String {
        let g = Double(bytes) / 1_073_741_824
        if g < 10 { return String(format: "%.1f ГБ", g) }
        return String(format: "%.0f ГБ", g)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d ч %02d мин", h, m) }
        if m > 0 { return String(format: "%d мин %02d с", m, s) }
        return "\(s) с"
    }
}

// MARK: - Лог сторожа

enum Log {
    private static let queue = DispatchQueue(label: "local.nespat.log")

    static func watchdog(_ message: String) {
        queue.sync {
            Paths.ensureDir(Paths.logDir)
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            if let handle = FileHandle(forWritingAtPath: Paths.watchdogLog.path) {
                handle.seekToEndOfFile()
                handle.write(line.data(using: .utf8)!)
                handle.closeFile()
            } else {
                FileManager.default.createFile(atPath: Paths.watchdogLog.path, contents: line.data(using: .utf8))
            }
        }
    }
}
