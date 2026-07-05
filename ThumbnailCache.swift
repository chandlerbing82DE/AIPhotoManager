import AppKit

// Klasa pomocnicza zarządzająca pamięcią podręczną obrazków (zapobiega zacinaniu się interfejsu)
class ThumbnailCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        
        // Limit ilości miniaturek w pamięci (np. 2000 zdjęć)
        cache.countLimit = 2000
        
        // Limit zużycia RAMu (np. ~200 MB)
        cache.totalCostLimit = 1024 * 1024 * 200
        
        return cache
    }()
}
