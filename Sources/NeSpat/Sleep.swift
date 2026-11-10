import Foundation
import IOKit

// MARK: - Состояние сна системы (IOKit, без subprocess в установившемся режиме)

enum SleepState: Equatable {
    case enabled      // обычный сон
    case disabled     // сон выключен
    case unknown      // не удалось прочитать
}

enum PowerInfo {
    /// IOPMrootDomain: SleepDisabled (источник правды на macOS 27).
    static func sleepState() -> SleepState {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return .unknown }
        if let b = value as? Bool { return b ? .disabled : .enabled }
        if let n = value as? Int { return n != 0 ? .disabled : .enabled }
        return .unknown
    }

    /// Крышка закрыта? nil, если свойство недоступно.
    static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else { return nil }
        return value
    }

    /// Запасной источник: pmset -g (на macOS 27 строка может отсутствовать).
    static func sleepStateViaPmset() -> SleepState? {
        let r = Proc.run("/usr/bin/pmset", ["-g"])
        guard r.ok else { return nil }
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[0] == "SleepDisabled" {
                return parts[1] == "1" ? .disabled : .enabled
            }
        }
        return nil
    }
}

// MARK: - Управление сном

enum SleepControl {
    enum Outcome: Equatable {
        case confirmed
        case notConfirmed
        case canceled   // владелец отменил диалог пароля
    }

    /// Включить/выключить сон и подтвердить у системы.
    /// Быстрый путь: sudo -n (кэш или правило). Иначе, если разрешено, — системный диалог пароля.
    @discardableResult
    static func setSleepDisabled(_ disabled: Bool, allowPrompt: Bool = true) -> Outcome {
        let fast = Proc.sudoPmset(disableSleep: disabled)
        if fast.ok {
            return verify(disabled) ? .confirmed : .notConfirmed
        }
        guard allowPrompt else { return .notConfirmed }
        let command = "/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)"
        let r = Proc.run("/usr/bin/osascript", [
            "-e", "do shell script \"\(command)\" with administrator privileges"
        ])
        if r.ok {
            return verify(disabled) ? .confirmed : .notConfirmed
        }
        if r.err.contains("-128") || r.err.lowercased().contains("cancel") {
            return .canceled
        }
        return .notConfirmed
    }

    /// Подтверждение: сначала IOKit, запасной — pmset.
    /// powerd применяет настройку асинхронно, поэтому даём системе до ~1 с.
    static func verify(_ expectDisabled: Bool) -> Bool {
        for _ in 0..<5 {
            let state = PowerInfo.sleepState()
            if state != .unknown {
                if state == (expectDisabled ? .disabled : .enabled) { return true }
            } else if let viaPmset = PowerInfo.sleepStateViaPmset(),
                      viaPmset == (expectDisabled ? .disabled : .enabled) {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    static func displaysleepnow() {
        _ = Proc.displaysleepnow()
    }
}
