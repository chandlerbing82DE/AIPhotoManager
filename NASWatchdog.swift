import Foundation
import AppKit

// =====================================================================
// LOGGER NAS WATCHDOG
// =====================================================================
class NASWatchdogLogger {
    static let shared = NASWatchdogLogger()
    private var fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.naswatchdog.logger")
    
    private init() {
        if let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            let logURL = desktopURL.appendingPathComponent("AIPhotoManager_NASWatchdog_Log.txt")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            fileHandle = try? FileHandle(forWritingTo: logURL)
            fileHandle?.seekToEndOfFile()
        }
        log("\n\n=======================================================")
        log("🚀 NOWA SESJA WATCHDOGA NAS: \(Date())")
        log("=======================================================")
    }
    
    func log(_ message: String) {
        queue.async {
            let msg = "[\(Date())] \(message)\n"
            self.fileHandle?.write(msg.data(using: .utf8) ?? Data())
            print(msg, terminator: "")
        }
    }
}

@MainActor
class NASWatchdog {
    static let shared = NASWatchdog()
    private var timer: Timer?
    
    // Zmienna zapobiegająca spamowaniu logów – loguje tylko zmiany stanu (podłączono/odłączono)
    private var wasConnected: Bool = true
    
    private init() {}
    
    func start() {
        guard timer == nil else { return }
        NASWatchdogLogger.shared.log("Uruchamiam usługę NAS Watchdog (pętla 30-sekundowa).")
        
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkAndRemount()
            }
        }
        
        // Zrób pierwsze sprawdzenie od razu
        checkAndRemount()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        NASWatchdogLogger.shared.log("Zatrzymano usługę NAS Watchdog.")
    }
    
    private func checkAndRemount() {
        let defaults = UserDefaults.standard
        let isEnabled = defaults.bool(forKey: "nasWatchdogEnabled")
        
        guard isEnabled else { return }
        
        let volumePath = defaults.string(forKey: "nasVolumePath") ?? "/Volumes/MEDIA"
        let smbAddress = defaults.string(forKey: "nasSmbAddress") ?? "smb://192.168.1.100/MEDIA"
        
        let fileManager = FileManager.default
        
        if !fileManager.fileExists(atPath: volumePath) {
            if wasConnected {
                NASWatchdogLogger.shared.log("⚠️ UWAGA: Dysk pod ścieżką \(volumePath) ZNIKNĄŁ z systemu!")
                NASWatchdogLogger.shared.log("🔌 Wysyłam żądanie podłączenia do adresu: \(smbAddress)")
                wasConnected = false
            }
            
            if let url = URL(string: smbAddress) {
                // Bezpośrednie wywołanie systemowe podmontowania dysku
                NSWorkspace.shared.open(url)
            } else {
                NASWatchdogLogger.shared.log("❌ BŁĄD: Podany adres SMB jest nieprawidłowy: \(smbAddress)")
            }
        } else {
            if !wasConnected {
                NASWatchdogLogger.shared.log("✅ SUKCES! Dysk \(volumePath) został pomyślnie zamontowany i jest znowu dostępny.")
                wasConnected = true
            }
        }
    }
}
