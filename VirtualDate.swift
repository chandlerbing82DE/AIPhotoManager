import Foundation

/// Reprezentuje wirtualną datę. Zapisujemy ją w bazie jako String (np. "XX.XX.199X"),
/// ale mamy metody do jej parsowania i sortowania.
struct VirtualDate: Codable, Equatable, Hashable {
    var rawString: String // Np. "24.12.19XX" lub "XX.XX.199X"
    
    init(rawString: String) {
        self.rawString = rawString
    }
    
    /// Estymowana data do celów sortowania w bazie
    var estimatedDate: Date {
        // Tu w przyszłości dodamy logikę, która np. "XX.XX.199X"
        // zamienia na 1990-01-01 do celów sortowania.
        return Date()
    }
    
    var isDecade: Bool { rawString.contains("X") && rawString.hasSuffix("X") }
}
