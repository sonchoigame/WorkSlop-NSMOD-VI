import UIKit

/// Image helpers for AirFlit, ported from AirCard's ImageEngine.
/// - Passcode themes: per-digit keypad PNGs staged for TelephonyUI caches.
/// - Wallet skins: multi-resolution card artwork for Passbook caches.
enum AirFlitImages {
    // MARK: - Basics

    static func normalize(_ image: UIImage, maxDimension: CGFloat = 2048) -> UIImage {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        let scale = min(1.0, maxDimension / max(size.width, size.height))
        let target = CGSize(width: max(1, floor(size.width * scale)),
                            height: max(1, floor(size.height * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = false
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// Aspect-fill resize to an exact size, PNG data.
    static func resizePNG(_ image: UIImage, to targetSize: CGSize) -> Data? {
        let imgSize = image.size
        guard imgSize.width > 0, imgSize.height > 0 else { return nil }
        let scale = max(targetSize.width / imgSize.width, targetSize.height / imgSize.height)
        let scaled = CGSize(width: imgSize.width * scale, height: imgSize.height * scale)
        let origin = CGPoint(x: (targetSize.width - scaled.width) / 2,
                             y: (targetSize.height - scaled.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        let out = UIGraphicsImageRenderer(size: targetSize, format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: scaled))
        }
        return out.pngData()
    }

    // MARK: - Passcode keypad

    /// English subtexts, same as iOS TelephonyUI.
    private static let subtexts: [String: String] = [
        "0": "+", "1": "", "2": "A B C", "3": "D E F",
        "4": "G H I", "5": "J K L", "6": "M N O",
        "7": "P Q R S", "8": "T U V", "9": "W X Y Z",
    ]

    /// Stages one PNG as the artwork for every keypad digit.
    /// English only (app is English-only): `en` + `other` locales,
    /// regular and bold weights — the same naming AirCard uses.
    /// Takes PNG `Data` directly (Sendable) so callers never need to
    /// ferry a non-Sendable UIImage across concurrency boundaries.
    /// Returns the number of files written.
    static func stagePasscodeTheme(pngData: Data, into dir: URL) -> Int {
        guard !pngData.isEmpty else { return 0 }
        var count = 0
        let langs = ["en", "other"]
        let bolds = ["", "-bold"]
        for digit in ["0","1","2","3","4","5","6","7","8","9"] {
            for lang in langs {
                for bld in bolds {
                    let names: [String]
                    if digit == "0" {
                        names = ["\(lang)-0---white\(bld).png",
                                 "\(lang)-0-+--white\(bld).png"]
                    } else if digit == "1" {
                        names = ["\(lang)-1---white\(bld).png"]
                    } else {
                        var n = ["\(lang)-\(digit)---white\(bld).png"]
                        let sub = subtexts[digit] ?? ""
                        if !sub.isEmpty {
                            n.append("\(lang)-\(digit)-\(sub)--white\(bld).png")
                            let noSpace = sub.replacingOccurrences(of: " ", with: "")
                            if noSpace != sub {
                                n.append("\(lang)-\(digit)-\(noSpace)--white\(bld).png")
                            }
                        }
                        names = n
                    }
                    for name in names {
                        try? pngData.write(to: dir.appendingPathComponent(name))
                        count += 1
                    }
                }
            }
        }
        // iOS TelephonyUI @3x high-res indicator marker (same as AirCard).
        try? Data().write(to: dir.appendingPathComponent("_big"))
        return count
    }

    // MARK: - Wallet card skins

    /// Generates all card artwork files AirCard produces:
    /// @3x (1536×969) + @2x (1024×646) PNGs plus PDF vectors.
    static func prepareCardSkins(from image: UIImage) -> [String: Data] {
        let normalized = normalize(image, maxDimension: 2560)
        var skins: [String: Data] = [:]
        if let d3 = resizePNG(normalized, to: CGSize(width: 1536, height: 969)) {
            skins["cardBackgroundCombined@3x.png"] = d3
            skins["diffuse@3x.png"] = d3
            skins["background@3x.png"] = d3
            skins["strip@3x.png"] = d3
        }
        if let d2 = resizePNG(normalized, to: CGSize(width: 1024, height: 646)) {
            skins["cardBackgroundCombined@2x.png"] = d2
            skins["diffuse@2x.png"] = d2
            skins["background@2x.png"] = d2
            skins["strip@2x.png"] = d2
        }
        let rect = CGRect(origin: .zero, size: CGSize(width: 1536, height: 969))
        let pdf = UIGraphicsPDFRenderer(bounds: rect).pdfData { ctx in
            ctx.beginPage()
            normalized.draw(in: rect)
        }
        skins["cardBackgroundCombined.pdf"] = pdf
        skins["background.pdf"] = pdf
        skins["strip.pdf"] = pdf
        return skins
    }

    /// Writes "corrupted" cache-invalidation leaves, same as AirCard:
    /// forces Wallet to re-read card art on next open (force-close
    /// the Wallet app after applying).
    static func stageCacheInvalidation(into dir: URL) {
        for leaf in ["FrontFace", "Preview", "PlaceHolder"] {
            try? Data("corrupted".utf8).write(to: dir.appendingPathComponent(leaf))
        }
    }
}
