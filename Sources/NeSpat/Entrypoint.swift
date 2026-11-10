import Foundation

// MARK: - Точка входа: CLI-режимы и GUI

@main
enum Entrypoint {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--watchdog") {
            Watchdog.run()
        }
        if args.contains("--print-stats") {
            printStats()
            exit(0)
        }
        if args.contains("--debug-sensors") {
            for s in TemperatureReader.debugSensors() {
                print("\(s.name.padding(toLength: 18, withPad: " ", startingAt: 0))\(String(format: "%.1f", s.value)) °C")
            }
            exit(0)
        }
        NeSpatApp.main()
    }

    /// Проверка из терминала: температура, CPU, память, батарея, сон, крышка.
    private static func printStats() {
        let sampler = StatsSampler()
        // Первый замер CPU без дельты — делаем два с паузой.
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 1)
        let s = sampler.sample()

        print("Температура чипа: \(s.temperatureC.map { String(format: "%.1f °C", $0) } ?? "—")")
        print("CPU: \(s.cpuPercent.map { String(format: "%.0f%%", $0) } ?? "—")")
        print("Память: \(Fmt.gb(s.memUsedBytes)) из \(Fmt.gb(s.memTotalBytes))")
        if let p = s.batteryPercent {
            print("Батарея: \(p)% (\(s.charging == true ? "на зарядке" : "от батареи"))")
        } else {
            print("Батарея: —")
        }
        switch PowerInfo.sleepState() {
        case .disabled: print("Сон: выключен (SleepDisabled=1)")
        case .enabled: print("Сон: включен (обычный)")
        case .unknown: print("Сон: неизвестно")
        }
        print("Крышка: \(PowerInfo.lidClosed() == true ? "закрыта" : "открыта")")
    }
}
