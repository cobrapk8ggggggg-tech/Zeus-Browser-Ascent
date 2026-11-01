import Foundation
import CoreGraphics
import CryptoKit

enum ComicReadingMode: String, Codable, CaseIterable { case fastest, balanced, careful
    var title: String { switch self { case .fastest: return "الأسرع"; case .balanced: return "متوازن"; case .careful: return "دقيق" } }
}
struct ComicPreferences: Codable, Equatable {
    static let sourceLanguages=TranslationPreferences.languages+[("el","Ελληνικά"),("hi","हिन्दी"),("th","ไทย"),("ta","தமிழ்"),("te","తెలుగు"),("uk","Українська")]
    var mode: ComicReadingMode = .fastest
    var source = "auto"
    var automatic = false
    var showUntranslated = false
    var readAhead = true
    var fontName: String?
    var localModel = false
    var fontScale: Double = 1
    var textColor: String?
    var engine: ComicOnlineEngine = .existing
    var translation: TranslationPreferences?
    func resolvedTranslation(_ settings:BrowserSettings)->TranslationPreferences{
        var value=translation ?? TranslationPreferences()
        if value.cloudflare==nil{value.cloudflare=settings.translation?.cloudflare}
        return value
    }
}
struct ComicCandidate: Codable, Identifiable {
    var id: String
    var source: String
    var kind: String
    var width: Int
    var height: Int
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var pending: Bool
    var revision: String
}
struct ComicEnvelope: Codable {
    var document: String
    var url: String
    var language: String
    var viewport: Double
    var scroll: Double
    var items: [ComicCandidate]
}
struct ComicRegion: Codable, Equatable {
    var x: Int = 0
    var y: Int
    var width: Int
    var height: Int
    var coreTop: Int
    var coreBottom: Int
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
struct ComicLine: Codable, Equatable {
    var text: String
    var confidence: Float
    var rect: CGRect
    var angle: Double = 0
}
struct ComicSpeech: Codable, Equatable {
    var id: String
    var text: String
    var lines: [ComicLine]
    var rect: CGRect
    var vertical: Bool
    var balloon: Bool = false
}
struct ComicReading: Codable { var lines: [ComicLine]; var speeches: [ComicSpeech]; var language: String; var runtime: String }
struct ComicCachedResult: Codable { var version = 1; var reading: ComicReading; var translations: [TranslationSegment] }
enum ComicFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}
enum ComicIdentity {
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ text: String) -> String { hash(Data(text.utf8)) }
    static func segmentIdentity(_ segments:[TranslationSegment])->String {
        hash(segments.map{$0.id+"\0"+$0.text}.joined(separator:"\n"))
    }
    static func settings(_ preferences: ComicPreferences, translation: TranslationPreferences, provider: AIProviderConfiguration?) -> String {
        hash("comic-v1|\(preferences.mode.rawValue)|\(preferences.source)|\(translation.target)|" + TranslationMemory.namespace(page: "comic://content", preferences: translation, provider: provider))
    }
}
enum ComicGeometry {
    // Overlap is context, not output ownership. Every source row belongs to one core.
    static func regions(width: Int, height: Int, maximumPixels: Int = 8_000_000) -> [ComicRegion] {
        guard width > 0, height > 0, width <= 16_384, height <= 1_000_000, maximumPixels >= width else { return [] }
        let rowBudget=maximumPixels/width
        let overlap = min(256, max(16, width / 8), max(0,(rowBudget-64)/2))
        let step = max(1, min(4096, rowBudget - overlap * 2))
        return stride(from: 0, to: height, by: step).map { top in
            let begin = max(0, top - overlap), end = min(height, top + step + overlap)
            return ComicRegion(y: begin, width: width, height: end - begin, coreTop: top - begin, coreBottom: min(height, top + step) - begin)
        }
    }
    static func prioritized(_ regions:[ComicRegion],candidate:ComicCandidate,scroll:Double,viewport:Double,readAhead:Bool)->[ComicRegion]{
        guard candidate.height>0,viewport>0 else{return []}
        func bounds(_ r:ComicRegion)->(Double,Double){let scale=candidate.h/Double(candidate.height);return(candidate.y+Double(r.y+r.coreTop)*scale,candidate.y+Double(r.y+r.coreBottom)*scale)}
        func distance(_ r:ComicRegion)->Double{let (top,bottom)=bounds(r);return max(0,top-scroll-viewport,scroll-bottom)}
        return regions.filter{r in let(top,bottom)=bounds(r);return bottom>=scroll-(readAhead ? viewport:0)&&top<=scroll+viewport*(readAhead ? 8:1)}.sorted{distance($0)<distance($1)}
    }
    static func group(_ input: [ComicLine], source: String) -> [ComicSpeech] {
        let lines = input.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.rect.width > 0 && $0.rect.height > 0 }
        var groups: [[ComicLine]] = []
        for line in lines.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            // Select among compatible groups: a nearer adjacent balloon must not
            // hide the correct group above this line.
            let compatible=groups.indices.filter{i in
                guard let last=groups[i].last else{return false}
                let gap=line.rect.minY-last.rect.maxY
                let overlap=min(line.rect.maxX,last.rect.maxX)-max(line.rect.minX,last.rect.minX)
                let vertical=line.rect.height>line.rect.width*1.5 && last.rect.height>last.rect.width*1.5
                if vertical{
                    let columnGap=max(line.rect.minX-last.rect.maxX,last.rect.minX-line.rect.maxX)
                    let verticalOverlap=min(line.rect.maxY,last.rect.maxY)-max(line.rect.minY,last.rect.minY)
                    return columnGap<max(line.rect.width,last.rect.width)*1.1 && verticalOverlap>min(line.rect.height,last.rect.height)*0.6
                }
                return gap >= -min(line.rect.height,last.rect.height)*0.5 && gap<max(line.rect.height,last.rect.height)*1.1 && overlap>min(line.rect.width,last.rect.width)*0.4
            }
            if let i=compatible.min(by:{abs(groups[$0].last!.rect.midY-line.rect.midY)<abs(groups[$1].last!.rect.midY-line.rect.midY)}){groups[i].append(line);continue}
            groups.append([line])
        }
        let japanese = source.hasPrefix("ja")
        return groups.enumerated().map { index, group in
            let bounds = group.reduce(CGRect.null) { $0.union($1.rect) }
            let vertical = group.allSatisfy { $0.rect.height > $0.rect.width * 1.5 }
            let ordered = group.sorted { vertical ? $0.rect.midX > $1.rect.midX : $0.rect.minY < $1.rect.minY }
            return ComicSpeech(id: String(index), text: ordered.map(\.text).joined(separator: vertical ? "" : "\n"), lines: ordered, rect: bounds, vertical: vertical)
        }.sorted { a,b in
            if abs(a.rect.minY-b.rect.minY) < min(a.rect.height,b.rect.height)*0.35 { return japanese ? a.rect.midX > b.rect.midX : a.rect.midX < b.rect.midX }
            return a.rect.minY < b.rect.minY
        }.enumerated().map { i,s in var s=s; s.id=String(i);return s }
    }
}
