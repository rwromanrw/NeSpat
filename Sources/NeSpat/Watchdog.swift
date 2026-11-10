import Foundation
import IOKit
import IOKit.ps

// MARK: - Сторож: --watchdog (LaunchAgent будит каждые 30 с, один проход и выход)

enum Watchdog {
    static func run() -> Never {
        tick()
        exit(0)
    }

    private static func tick() {
        let session = SessionStore.load()
        guard session.owned else { return }

        // Таймер истёк — возвращаем сон (страховка даже при живом приложении).
        if let until = session.until, until <= Date() {
            restore("таймер истёк")
            return
        }

        // Приложение мертво — возвращаем сон.
        if !ownerAlive(session) {
            restore("приложение не запущено")
            return
        }

        // Живое приложение само следит за батареей и теплом; здесь страховка от зависшего процесса.
        if batteryCritical() || thermalSerious() {
            restore("перегрев или низкий заряд (страховка)")
        }
    }

    private static func ownerAlive(_ s: Session) -> Bool {
        guard s.pid > 0, kill(s.pid, 0) == 0 else { return false }
        // Убеждаемся, что pid принадлежит NeSpat, а не переиспользован системой.
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let len = proc_pidpath(s.pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return false }
        let path = String(decoding: buffer.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.contains("NeSpat")
    }

    private static func batteryCritical() -> Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(blob, ps as CFTypeRef)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let onBattery = desc[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let percent = max > 0 ? current * 100 / max : 100
            return onBattery && percent < 15
        }
        return false
    }

    private static func thermalSerious() -> Bool {
        ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
    }

    private static func restore(_ reason: String) {
        // Сначала без диалога (sudo -n / кэш). Если не вышло — один системный запрос пароля:
        // без sudoers иначе после падения приложения сон так и останется выключенным.
        var outcome = SleepControl.setSleepDisabled(false, allowPrompt: false)
        if outcome != .confirmed {
            outcome = SleepControl.setSleepDisabled(false, allowPrompt: true)
        }

        let sleepAlreadyOn = PowerInfo.sleepState() == .enabled
        if outcome == .confirmed || sleepAlreadyOn {
            var s = SessionStore.load()
            s.owned = false
            s.until = nil
            s.lastReason = "Сон возвращён: \(reason)"
            SessionStore.save(s)
            Log.watchdog("sleep restored: \(reason)")
        } else if outcome == .canceled {
            Log.watchdog("restore canceled by user (\(reason))")
        } else {
            Log.watchdog("failed to restore sleep (\(reason)): \(outcome)")
        }
    }
}
