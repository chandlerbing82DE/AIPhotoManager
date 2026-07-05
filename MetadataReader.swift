import Foundation
import ImageIO

// Struktura musi być Sendable dla Swift 6
struct PhotoMetadata: Sendable {
    var dimensions: String
    var cameraModel: String
    var dateTimeOriginal: String
    var xmpDescription: String?
    var xmpKeywords: [String]
    var debugInfo: String
    
    // POPRAWIONE: nonisolated init
    nonisolated init() {
        self.dimensions = "Nieznane"
        self.cameraModel = "Nieznany"
        self.dateTimeOriginal = "Brak daty"
        self.xmpDescription = nil
        self.xmpKeywords = []
        self.debugInfo = ""
    }
}


struct MetadataReader: Sendable {
    
    nonisolated static func readMetadata(from path: String) -> PhotoMetadata {
        var meta = PhotoMetadata()
        let url = URL(fileURLWithPath: path)
        
        // 1. Odczyt EXIF/TIFF (sprzętowe)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] {
            
            if let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? Int,
               let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? Int {
                meta.dimensions = "\(pixelWidth) x \(pixelHeight) px"
            }
            if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any],
               let model = tiff[kCGImagePropertyTIFFModel as String] as? String {
                meta.cameraModel = model
            }
            if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any],
               let date = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
                meta.dateTimeOriginal = date
            }
        }
        
        // 2. Szukanie pliku XMP
        let xmpUrl1 = url.deletingPathExtension().appendingPathExtension("xmp")
        let xmpUrl2 = url.appendingPathExtension("xmp")
        
        let possibleUrls = [xmpUrl1, xmpUrl2]
        var xmpContent: String? = nil
        var foundUrl: URL? = nil
        
        for testUrl in possibleUrls {
            if FileManager.default.fileExists(atPath: testUrl.path) {
                foundUrl = testUrl
                do {
                    xmpContent = try String(contentsOf: testUrl, encoding: .utf8)
                    meta.debugInfo = "Pomyślnie wczytano plik: \(testUrl.lastPathComponent)"
                    break
                } catch {
                    meta.debugInfo = "Plik \(testUrl.lastPathComponent) istnieje, ale nie można odczytać: \(error.localizedDescription)"
                }
            }
        }
        
        if foundUrl == nil {
            meta.debugInfo = "Nie znaleziono pliku. Szukano: \(xmpUrl1.lastPathComponent) oraz \(xmpUrl2.lastPathComponent)"
        }
        
        // 3. Parsowanie XMP
        if let xmpString = xmpContent {
            if let descRange = xmpString.range(of: "(?s)<dc:description>.*?</dc:description>", options: .regularExpression) {
                let descBlock = String(xmpString[descRange])
                if let liRange = descBlock.range(of: "(?s)<rdf:li[^>]*>(.*?)</rdf:li>", options: .regularExpression) {
                    let liString = String(descBlock[liRange])
                    meta.xmpDescription = liString.replacingOccurrences(of: "(?s)<[^>]+>", with: "", options: .regularExpression).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                }
            }
            
            if let subjRange = xmpString.range(of: "(?s)<dc:subject>.*?</dc:subject>", options: .regularExpression) {
                let subjBlock = String(xmpString[subjRange])
                if let regex = try? NSRegularExpression(pattern: "(?s)<rdf:li[^>]*>(.*?)</rdf:li>") {
                    let matches = regex.matches(in: subjBlock, range: NSRange(subjBlock.startIndex..., in: subjBlock))
                    for match in matches {
                        if let range = Range(match.range(at: 1), in: subjBlock) {
                            meta.xmpKeywords.append(String(subjBlock[range]))
                        }
                    }
                }
            }
        }
        
        return meta
    }
}
