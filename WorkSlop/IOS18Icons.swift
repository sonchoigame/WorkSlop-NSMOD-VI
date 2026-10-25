import UIKit
import CryptoKit
import ImageIO

/// iOS 18 stock icon gallery (from the user's icon pack,
/// "iOS 18 App Icons by catwithabaloon"). Three tables on the Custom
/// Icons page: Light, Dark and Tinted. Tapping one adds it as a custom icon
/// entry (name + bundle ID + the icon image) - bundle IDs verified
/// against the iTunes lookup for each app. Icons are 60x60 PNG,
/// exactly as supplied in the pack (the Tinted set is the official
/// catwithabaloon 2.0 artwork, byte-identical copies under
/// iOS18Icons/Tinted).
struct IOS18Icon: Identifiable {
    let name: String
    let bundleID: String
    let slug: String
    var id: String { slug }
}

/// Gallery variant: the Light and Dark tables from the pack,
/// plus the Tinted set (official catwithabaloon 2.0 artwork,
/// byte-identical copies under iOS18Icons/Tinted), plus 7 custom
/// tinted color variants generated from the Light artwork.
enum IconVariant: CaseIterable {
    case light, dark, tinted
    case tintedGreen, tintedYellow, tintedBlue
    case tintedWhite, tintedGray, tintedBrown, tintedCream

    var label: String {
        switch self {
        case .light: return "light"
        case .dark: return "dark"
        case .tinted: return "tinted"
        case .tintedGreen: return "tinted-green"
        case .tintedYellow: return "tinted-yellow"
        case .tintedBlue: return "tinted-blue"
        case .tintedWhite: return "tinted-white"
        case .tintedGray: return "tinted-gray"
        case .tintedBrown: return "tinted-brown"
        case .tintedCream: return "tinted-cream"
        }
    }

    var title: String {
        switch self {
        case .light: return "Sáng"
        case .dark: return "Tối"
        case .tinted: return "Phủ màu"
        case .tintedGreen: return "Phủ màu xanh lá"
        case .tintedYellow: return "Phủ màu vàng"
        case .tintedBlue: return "Phủ màu xanh dương"
        case .tintedWhite: return "Phủ màu trắng"
        case .tintedGray: return "Phủ màu xám"
        case .tintedBrown: return "Phủ màu nâu"
        case .tintedCream: return "Phủ màu kem"
        }
    }

    var subdirectory: String {
        switch self {
        case .light: return "iOS18Icons/Light"
        case .dark: return "iOS18Icons/Dark"
        case .tinted: return "iOS18Icons/Tinted"
        case .tintedGreen: return "iOS18Icons/TintedGreen"
        case .tintedYellow: return "iOS18Icons/TintedYellow"
        case .tintedBlue: return "iOS18Icons/TintedBlue"
        case .tintedWhite: return "iOS18Icons/TintedWhite"
        case .tintedGray: return "iOS18Icons/TintedGray"
        case .tintedBrown: return "iOS18Icons/TintedBrown"
        case .tintedCream: return "iOS18Icons/TintedCream"
        }
    }
}

enum IOS18IconCatalog {
    static let all: [IOS18Icon] = [
        IOS18Icon(name: "Shortcuts", bundleID: "com.apple.shortcuts", slug: "shortcuts"),
        IOS18Icon(name: "App Store", bundleID: "com.apple.AppStore", slug: "app-store"),
        IOS18Icon(name: "Settings", bundleID: "com.apple.Preferences", slug: "settings"),
        IOS18Icon(name: "Numbers", bundleID: "com.apple.Numbers", slug: "numbers"),
        IOS18Icon(name: "Pages", bundleID: "com.apple.Pages", slug: "pages"),
        IOS18Icon(name: "Keynote", bundleID: "com.apple.Keynote", slug: "keynote"),
        IOS18Icon(name: "Books", bundleID: "com.apple.iBooks", slug: "books"),
        IOS18Icon(name: "Calculator", bundleID: "com.apple.calculator", slug: "calculator"),
        IOS18Icon(name: "Calendar", bundleID: "com.apple.mobilecal", slug: "calendar"),
        IOS18Icon(name: "Camera", bundleID: "com.apple.camera", slug: "camera"),
        IOS18Icon(name: "Music Classical", bundleID: "com.apple.music.classical", slug: "music-classical"),
        IOS18Icon(name: "Clock", bundleID: "com.apple.mobiletimer", slug: "clock"),
        IOS18Icon(name: "Compass", bundleID: "com.apple.compass", slug: "compass"),
        IOS18Icon(name: "Contacts", bundleID: "com.apple.AddressBook", slug: "contacts"),
        IOS18Icon(name: "FaceTime", bundleID: "com.apple.facetime", slug: "facetime"),
        IOS18Icon(name: "Files", bundleID: "com.apple.DocumentsApp", slug: "files"),
        IOS18Icon(name: "Clips", bundleID: "com.apple.clips", slug: "clips"),
        IOS18Icon(name: "Find My", bundleID: "com.apple.findmy", slug: "find-my"),
        IOS18Icon(name: "Fitness", bundleID: "com.apple.Fitness", slug: "fitness"),
        IOS18Icon(name: "GarageBand", bundleID: "com.apple.mobilegarageband", slug: "garageband"),
        IOS18Icon(name: "Health", bundleID: "com.apple.Health", slug: "health"),
        IOS18Icon(name: "Home", bundleID: "com.apple.Home", slug: "home"),
        IOS18Icon(name: "Magnifier", bundleID: "com.apple.Magnifier", slug: "magnifier"),
        IOS18Icon(name: "Mail", bundleID: "com.apple.mobilemail", slug: "mail"),
        IOS18Icon(name: "Maps", bundleID: "com.apple.Maps", slug: "maps"),
        IOS18Icon(name: "Measure", bundleID: "com.apple.measure", slug: "measure"),
        IOS18Icon(name: "Music", bundleID: "com.apple.Music", slug: "music"),
        IOS18Icon(name: "News", bundleID: "com.apple.news", slug: "news"),
        IOS18Icon(name: "Notes", bundleID: "com.apple.mobilenotes", slug: "notes"),
        IOS18Icon(name: "Passwords", bundleID: "com.apple.Passwords", slug: "passwords"),
        IOS18Icon(name: "Phone", bundleID: "com.apple.mobilephone", slug: "phone"),
        IOS18Icon(name: "Photos", bundleID: "com.apple.mobileslideshow", slug: "photos"),
        IOS18Icon(name: "Podcasts", bundleID: "com.apple.podcasts", slug: "podcasts"),
        IOS18Icon(name: "Reminders", bundleID: "com.apple.reminders", slug: "reminders"),
        IOS18Icon(name: "Apple TV Remote", bundleID: "com.apple.TVRemote", slug: "apple-tv-remote"),
        IOS18Icon(name: "Safari", bundleID: "com.apple.mobilesafari", slug: "safari"),
        IOS18Icon(name: "Stocks", bundleID: "com.apple.stocks", slug: "stocks"),
        IOS18Icon(name: "Apple Store", bundleID: "com.apple.store.Jolly", slug: "apple-store"),
        IOS18Icon(name: "Swift Playgrounds", bundleID: "com.apple.Playgrounds", slug: "swift-playgrounds"),
        IOS18Icon(name: "TestFlight", bundleID: "com.apple.TestFlight", slug: "testflight"),
        IOS18Icon(name: "Tips", bundleID: "com.apple.tips", slug: "tips"),
        IOS18Icon(name: "Translate", bundleID: "com.apple.Translate", slug: "translate"),
        IOS18Icon(name: "Voice Memos", bundleID: "com.apple.VoiceMemos", slug: "voice-memos"),
        IOS18Icon(name: "Wallet", bundleID: "com.apple.Passbook", slug: "wallet"),
        IOS18Icon(name: "Watch", bundleID: "com.apple.Bridge", slug: "watch"),
        IOS18Icon(name: "Weather", bundleID: "com.apple.weather", slug: "weather"),
        IOS18Icon(name: "Messages", bundleID: "com.apple.MobileSMS", slug: "messages"),
        IOS18Icon(name: "iMovie", bundleID: "com.apple.iMovie", slug: "imovie"),
        IOS18Icon(name: "Apple Sports", bundleID: "com.apple.sports", slug: "apple-sports"),
        IOS18Icon(name: "TV", bundleID: "com.apple.tv", slug: "tv"),
        IOS18Icon(name: "Shazam", bundleID: "com.shazam.Shazam", slug: "shazam"),
        // Tinted-only entries (catwithabaloon 2.0 pack has 67 tinted PNGs;
        // these 5 have desktop-verified Apple bundle IDs).
        IOS18Icon(name: "Freeform", bundleID: "com.apple.Freeform", slug: "freeform"),
        IOS18Icon(name: "Journal", bundleID: "com.apple.Journal", slug: "journal"),
        IOS18Icon(name: "Feedback", bundleID: "com.apple.FeedbackAssistant", slug: "feedback"),
        IOS18Icon(name: "Image Playground", bundleID: "com.apple.ImagePlayground", slug: "image-playground"),
        IOS18Icon(name: "Final Cut Camera", bundleID: "com.apple.FinalCutCamera", slug: "final-cut-camera"),
    ]

    static func imageData(slug: String, dark: Bool) -> Data? {
        let sub = dark ? "iOS18Icons/Dark" : "iOS18Icons/Light"
        guard let url = Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: sub)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Decoded gallery thumbnails, cached for the whole session.
    /// The gallery lists ~100 rows; decoding PNG data on every
    /// render was a real source of scroll lag.
    private static let imageCache = NSCache<NSString, UIImage>()

    static func image(slug: String, dark: Bool) -> UIImage? {
        let key = (dark ? "d:" : "l:") + slug as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let data = imageData(slug: slug, dark: dark),
              let img = UIImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    static func hasLight(slug: String) -> Bool {
        Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: "iOS18Icons/Light") != nil
    }

    static func hasDark(slug: String) -> Bool {
        Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: "iOS18Icons/Dark") != nil
    }

    static func hasTinted(slug: String) -> Bool {
        Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: "iOS18Icons/Tinted") != nil
    }

    /// Generic: check if a variant has artwork for a slug
    static func hasVariant(_ variant: IconVariant, slug: String) -> Bool {
        Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: variant.subdirectory) != nil
    }

    /// Generic: load image data for any variant
    static func variantImageData(_ variant: IconVariant, slug: String) -> Data? {
        guard let url = Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: variant.subdirectory)
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Generic: decoded + cached image for any variant
    static func variantImage(_ variant: IconVariant, slug: String) -> UIImage? {
        let key = (variant.label + ":" + slug) as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let data = variantImageData(variant, slug: slug),
              let img = UIImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    /// Icons for a given variant, filtered once
    static func icons(for variant: IconVariant) -> [IOS18Icon] {
        all.filter { hasVariant(variant, slug: $0.slug) }
    }

    static func tintedImageData(slug: String) -> Data? {
        guard let url = Bundle.main.url(forResource: slug, withExtension: "png", subdirectory: "iOS18Icons/Tinted")
        else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Decoded Tinted thumbnails, cached for the whole session
    /// (same reasoning as the Light/Dark image cache).
    static func tintedImage(slug: String) -> UIImage? {
        let key = ("t:" + slug) as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let data = tintedImageData(slug: slug),
              let img = UIImage(data: data) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    /// The icons that have Light artwork, filtered once. Entries
    /// without a Light PNG used to show in the Light table as a
    /// thumbnail-less row whose tap was a silent no-op - they are
    /// excluded here instead (same pattern as darkIcons/tintedIcons).
    static let lightIcons: [IOS18Icon] = all.filter { hasLight(slug: $0.slug) }

    /// The icons that have Dark artwork, filtered once. The Custom
    /// Icons page used to re-run this filter (a bundle file lookup
    /// per icon) on every render of its ~100-row list.
    static let darkIcons: [IOS18Icon] = all.filter { hasDark(slug: $0.slug) }

    /// The icons that have Tinted artwork, filtered once (same
    /// pattern as darkIcons).
    static let tintedIcons: [IOS18Icon] = all.filter { hasTinted(slug: $0.slug) }
}

// MARK: - Staged custom icons

/// Custom icon for one app: image + bundle id + display name, staged
/// like the desktop Icon Themes flow. The staged entry rides the
/// parameterized WebClip write in PayloadSpec.swift.
struct CustomIconEntry: Identifiable, Codable {
    var id = UUID()
    var bundleID: String = ""
    var appName: String = ""
    var imageData: Data? = nil
}

/// Decoded images for the user's own staged icons, cached by a
/// full-content hash of the image data. Thumbnails are decoded
/// downsampled (the row shows 44pt); the editor preview keeps a
/// full-size decode, also cached.
enum EntryImageCache {
    private static let thumbnails = NSCache<NSString, UIImage>()
    private static let fullSize = NSCache<NSString, UIImage>()

    private static func fingerprint(_ data: Data) -> NSString {
        // Full-content SHA-256: the key identifies the exact image
        // bytes, so replacing an icon with a same-size edit can
        // never leave a stale thumbnail (or stale preview) behind.
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        return "\(data.count):\(digest)" as NSString
    }

    static func thumbnail(_ data: Data) -> UIImage? {
        let key = fingerprint(data)
        if let hit = thumbnails.object(forKey: key) { return hit }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // 44pt row at up to 3x - same pixels the row displays.
            kCGImageSourceThumbnailMaxPixelSize: 132,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return UIImage(data: data) }
        let img = UIImage(cgImage: cg)
        thumbnails.setObject(img, forKey: key)
        return img
    }

    static func full(_ data: Data) -> UIImage? {
        let key = fingerprint(data)
        if let hit = fullSize.object(forKey: key) { return hit }
        guard let img = UIImage(data: data) else { return nil }
        fullSize.setObject(img, forKey: key)
        return img
    }
}

enum CustomIconStore {
    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("custom-icons.json")
    }

    static func load() -> [CustomIconEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([CustomIconEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func save(_ entries: [CustomIconEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
