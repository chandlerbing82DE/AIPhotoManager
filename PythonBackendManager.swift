import Foundation
import AppKit

class PythonBackendManager {
    static let shared = PythonBackendManager()
    private var process: Process?
    private var logFileHandle: FileHandle?
    
    private func killZombieServer() {
        let killTask = Process()
        killTask.executableURL = URL(fileURLWithPath: "/bin/sh")
        killTask.arguments = ["-c", "lsof -ti :8000 | xargs kill -9"]
        try? killTask.run()
        killTask.waitUntilExit()
    }
    
    func startServer() {
        // 🚨 BŁĄD ZNALEZIONY: Zamiast "guard process == nil", sprawdzamy czy proces FAKTYCZNIE działa!
        if let existingProcess = process, existingProcess.isRunning {
            return // Serwer nadal żyje i ma się dobrze
        }
        
        killZombieServer() // Sprzątamy port 8000
        
        let newProcess = Process()
        
        guard let executablePath = Bundle.main.url(forResource: "face_server", withExtension: nil) else {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Brak pliku face_server"
                alert.informativeText = "Nie znaleziono silnika AI! Upewnij się, że plik face_server jest w projekcie."
                alert.alertStyle = .critical
                alert.runModal()
            }
            return
        }
        
        newProcess.executableURL = executablePath
        
        let desktopURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first!
        let logURL = desktopURL.appendingPathComponent("AIPhotoManager_Python_Log.txt")
        
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        
        logFileHandle = try? FileHandle(forWritingTo: logURL)
        logFileHandle?.seekToEndOfFile()
        let startupMsg = "\n\n--- NOWY START APLIKACJI: \(Date()) ---\n"
        logFileHandle?.write(startupMsg.data(using: .utf8)!)
        
        let pipe = Pipe()
        newProcess.standardOutput = pipe
        newProcess.standardError = pipe
        
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty {
                self?.logFileHandle?.write(data)
                if let str = String(data: data, encoding: .utf8) { print(str, terminator: "") }
            }
        }
        
        do {
            try newProcess.run()
            self.process = newProcess
            let successMsg = "✅ Serwer Python uruchomiony pomyślnie (PID: \(newProcess.processIdentifier))\n"
            logFileHandle?.write(successMsg.data(using: .utf8)!)
        } catch {
            print("Błąd uruchamiania serwera: \(error)")
        }
    }
    
    func stopServer() {
        if let process = process, process.isRunning {
            process.terminate()
            let stopMsg = "🛑 Serwer Python bezpiecznie zatrzymany.\n"
            logFileHandle?.write(stopMsg.data(using: .utf8)!)
        }
        process = nil
        logFileHandle?.closeFile()
    }
}
