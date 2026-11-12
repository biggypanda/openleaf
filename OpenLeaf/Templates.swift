import SwiftUI
import UIKit

// MARK: - Şablonlar (Cornell, milimetrik, nota, planlayıcılar, sınav tabloları)
//
// Hepsi kodla çizilir: her yakınlıkta net kalır, PDF'e vektör olarak çıkar, dosya boyutu büyümez.
// Ölçüler sayfa birimiyle (`s` ile çarpılır); sütun genişlikleri sayfa genişliğinden türetilir
// ki A4, A5 ve Mektup boyutlarının hepsinde düzgün otursun.

extension PaperPattern {
    /// Uygulamanın dili (cihaz bölgesi değil): gün adları ve büyük harfe çevirme bununla yapılır
    private static let appLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "tr")

    /// Pazartesiden başlayan gün adları: uzun ("Pazartesi") ve kısa ("Pzt")
    private static let weekdays: (long: [String], short: [String]) = {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = appLocale
        let order = [1, 2, 3, 4, 5, 6, 0]
        func cap(_ s: String) -> String { s.prefix(1).uppercased(with: appLocale) + s.dropFirst() }
        return (order.map { cap(cal.standaloneWeekdaySymbols[$0]) }, order.map { cap(cal.shortStandaloneWeekdaySymbols[$0]) })
    }()

    private static func caps(_ s: String) -> String { s.uppercased(with: appLocale) }

    static func drawTemplate(_ style: PaperStyle, in r: CGRect, scale s: CGFloat,
                             stroke: Stroke, fill: Fill, text: Label) {
        let m = 40 * s
        let left = r.minX + m, right = r.maxX - m
        let lineW = max(0.5, 1 * s), ruleW = max(0.6, 1.2 * s)
        func h(_ p: inout Path, _ y: CGFloat, _ x0: CGFloat, _ x1: CGFloat) {
            p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: x1, y: y))
        }
        func v(_ p: inout Path, _ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat) {
            p.move(to: CGPoint(x: x, y: y0)); p.addLine(to: CGPoint(x: x, y: y1))
        }

        switch style {
        case .cornell:
            // Üstte başlık, solda anahtar kelimeler, sağda notlar, altta özet
            let top = r.minY + 96 * s, bottom = r.maxY - 196 * s
            let cue = r.minX + r.width * 0.28
            var lines = Path()
            var y = top + 34 * s
            while y < bottom - 8 * s { h(&lines, y, cue, r.maxX); y += 34 * s }
            y = bottom + 34 * s
            while y < r.maxY - 20 * s { h(&lines, y, r.minX, r.maxX); y += 34 * s }
            stroke(lines, Y.paperLineUI, lineW)
            var rules = Path()
            h(&rules, top, r.minX, r.maxX)
            h(&rules, bottom, r.minX, r.maxX)
            v(&rules, cue, top, bottom)
            stroke(rules, Y.paperMarginUI, ruleW)
            text(caps(String(localized: "Anahtar kelimeler")), CGPoint(x: r.minX + 14 * s, y: top + 17 * s), 9.5 * s, .leading)
            text(caps(String(localized: "Notlar")), CGPoint(x: cue + 14 * s, y: top + 17 * s), 9.5 * s, .leading)
            text(caps(String(localized: "Özet")), CGPoint(x: r.minX + 14 * s, y: bottom + 17 * s), 9.5 * s, .leading)

        case .milimetrik:
            // İnce kareler, her beşincisi belirgin
            let step = 7 * s
            var minor = Path(), major = Path()
            var i = 1
            var x = r.minX + step
            while x < r.maxX {
                if i % 5 == 0 { v(&major, x, r.minY, r.maxY) } else { v(&minor, x, r.minY, r.maxY) }
                x += step; i += 1
            }
            i = 1
            var y = r.minY + step
            while y < r.maxY {
                if i % 5 == 0 { h(&major, y, r.minX, r.maxX) } else { h(&minor, y, r.minX, r.maxX) }
                y += step; i += 1
            }
            stroke(minor, Y.paperLineFaintUI, max(0.35, 0.6 * s))
            stroke(major, Y.paperLineUI, max(0.5, 1 * s))

        case .nota:
            // Beş çizgili porteler
            let gap = 10 * s
            let x0 = r.minX + 44 * s, x1 = r.maxX - 44 * s
            var p = Path()
            var y = r.minY + 110 * s
            while y + 4 * gap < r.maxY - 44 * s {
                for k in 0..<5 { h(&p, y + CGFloat(k) * gap, x0, x1) }
                v(&p, x0, y, y + 4 * gap)
                v(&p, x1, y, y + 4 * gap)
                y += 4 * gap + 62 * s
            }
            stroke(p, Y.paperRuleUI, max(0.5, 0.9 * s))

        case .haftalik:
            // Yedi gün + notlar: iki sütun, dört satır
            let top = r.minY + 84 * s
            let area = CGRect(x: left, y: top, width: right - left, height: r.maxY - m - top)
            let cw = area.width / 2, ch = area.height / 4
            text(String(localized: "Hafta"), CGPoint(x: left, y: r.minY + 52 * s), 13 * s, .leading)
            var lines = Path(), rules = Path()
            h(&rules, r.minY + 62 * s, left + 58 * s, left + 280 * s)
            rules.addRect(area)
            v(&rules, area.midX, area.minY, area.maxY)
            for row in 1..<4 { h(&rules, area.minY + CGFloat(row) * ch, area.minX, area.maxX) }
            for i in 0..<8 {
                let cell = CGRect(x: area.minX + CGFloat(i % 2) * cw, y: area.minY + CGFloat(i / 2) * ch, width: cw, height: ch)
                let name = i < 7 ? weekdays.long[i] : String(localized: "Notlar")
                text(name, CGPoint(x: cell.minX + 12 * s, y: cell.minY + 20 * s), 12 * s, .leading)
                var y = cell.minY + 64 * s
                while y < cell.maxY - 10 * s { h(&lines, y, cell.minX + 12 * s, cell.maxX - 12 * s); y += 30 * s }
            }
            stroke(lines, Y.paperLineUI, lineW)
            stroke(rules, Y.paperRuleUI, ruleW)

        case .dersProgrami:
            // Saat sütunu + yedi gün
            let top = r.minY + 84 * s
            let head = 36 * s, timeW = 62 * s, rowH = 60 * s
            let rows = max(1, Int((r.maxY - m - top - head) / rowH))
            let bottom = top + head + CGFloat(rows) * rowH
            let colW = (right - left - timeW) / 7
            var lines = Path(), rules = Path()
            for k in 1..<7 { v(&lines, left + timeW + CGFloat(k) * colW, top, bottom) }
            for k in 1..<rows { h(&lines, top + head + CGFloat(k) * rowH, left, right) }
            rules.addRect(CGRect(x: left, y: top, width: right - left, height: bottom - top))
            h(&rules, top + head, left, right)
            v(&rules, left + timeW, top, bottom)
            stroke(lines, Y.paperLineUI, lineW)
            stroke(rules, Y.paperRuleUI, ruleW)
            text(String(localized: "Saat"), CGPoint(x: left + timeW / 2, y: top + head / 2), 11 * s, .center)
            for k in 0..<7 {
                text(weekdays.short[k], CGPoint(x: left + timeW + (CGFloat(k) + 0.5) * colW, y: top + head / 2), 11 * s, .center)
            }

        case .konuTakip:
            // Konu listesi + üç işaret kutusu: çalıştım, soru çözdüm, tekrar ettim
            let top = r.minY + 96 * s
            let head = 36 * s, rowH = 34 * s, checkW = 84 * s
            let rows = max(1, Int((r.maxY - m - top - head) / rowH))
            let bottom = top + head + CGFloat(rows) * rowH
            let x1 = right - 3 * checkW
            text(String(localized: "Ders"), CGPoint(x: left, y: r.minY + 54 * s), 13 * s, .leading)
            var lines = Path(), rules = Path(), boxes = Path()
            h(&rules, r.minY + 64 * s, left + 50 * s, left + 300 * s)
            for k in 1..<rows { h(&lines, top + head + CGFloat(k) * rowH, left, right) }
            rules.addRect(CGRect(x: left, y: top, width: right - left, height: bottom - top))
            h(&rules, top + head, left, right)
            for k in 0..<3 { v(&rules, x1 + CGFloat(k) * checkW, top, bottom) }
            let box = 13 * s
            for row in 0..<rows {
                let cy = top + head + (CGFloat(row) + 0.5) * rowH
                for k in 0..<3 {
                    let cx = x1 + (CGFloat(k) + 0.5) * checkW
                    boxes.addRoundedRect(in: CGRect(x: cx - box / 2, y: cy - box / 2, width: box, height: box),
                                         cornerSize: CGSize(width: 2.5 * s, height: 2.5 * s))
                }
            }
            stroke(lines, Y.paperLineUI, lineW)
            stroke(rules, Y.paperRuleUI, ruleW)
            stroke(boxes, Y.paperRuleUI, lineW)
            text(String(localized: "Konu"), CGPoint(x: left + 12 * s, y: top + head / 2), 11 * s, .leading)
            let checks = [String(localized: "Çalıştım"), String(localized: "Soru çözdüm"), String(localized: "Tekrar")]
            for k in 0..<3 {
                text(checks[k], CGPoint(x: x1 + (CGFloat(k) + 0.5) * checkW, y: top + head / 2), 10.5 * s, .center)
            }

        case .denemeAnalizi:
            // Deneme sınavı: ders başına soru/doğru/yanlış/boş/net tablosu + yanlış yapılan konular
            let top = r.minY + 96 * s
            let head = 36 * s, rowH = 40 * s, colW = 76 * s
            let rows = 9 // sekiz ders + toplam
            let bottom = top + head + CGFloat(rows) * rowH
            let x1 = right - 5 * colW
            let mid = left + (right - left) * 0.56
            text(String(localized: "Deneme"), CGPoint(x: left, y: r.minY + 54 * s), 13 * s, .leading)
            text(String(localized: "Tarih"), CGPoint(x: mid, y: r.minY + 54 * s), 13 * s, .leading)
            var lines = Path(), rules = Path()
            h(&rules, r.minY + 64 * s, left + 72 * s, mid - 24 * s)
            h(&rules, r.minY + 64 * s, mid + 48 * s, right)
            for k in 1..<rows - 1 { h(&lines, top + head + CGFloat(k) * rowH, left, right) }
            for k in 1..<5 { v(&lines, x1 + CGFloat(k) * colW, top, bottom) }
            rules.addRect(CGRect(x: left, y: top, width: right - left, height: bottom - top))
            h(&rules, top + head, left, right)
            h(&rules, bottom - rowH, left, right)
            v(&rules, x1, top, bottom)
            text(String(localized: "Ders"), CGPoint(x: left + 12 * s, y: top + head / 2), 11 * s, .leading)
            let cols = [String(localized: "Soru"), String(localized: "Doğru"), String(localized: "Yanlış"),
                        String(localized: "Boş"), String(localized: "Net")]
            for k in 0..<5 {
                text(cols[k], CGPoint(x: x1 + (CGFloat(k) + 0.5) * colW, y: top + head / 2), 11 * s, .center)
            }
            text(String(localized: "Toplam"), CGPoint(x: left + 12 * s, y: bottom - rowH / 2), 11 * s, .leading)
            let notesTop = bottom + 46 * s
            text(String(localized: "Yanlış yaptığım konular"), CGPoint(x: left, y: notesTop), 12 * s, .leading)
            var y = notesTop + 46 * s
            while y < r.maxY - m + 1 { h(&lines, y, left, right); y += 34 * s }
            stroke(lines, Y.paperLineUI, lineW)
            stroke(rules, Y.paperRuleUI, ruleW)

        case .cizgili, .kareli, .noktali, .bos:
            break
        }
    }
}

/// Şablon yazılarını Core Graphics bağlamına çizer (sayfa altlığı, küçük resim ve PDF dışa aktarma).
/// Döşemeli katman arka plan iş parçacığında çizer; metin çizimi orada da güvenlidir.
enum PaperText {
    static func draw(_ string: String, at p: CGPoint, size: CGFloat, align: PaperPattern.Align,
                     color: UIColor, in cg: CGContext) {
        guard size >= 3 else { return }
        let text = NSAttributedString(string: string, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .medium),
            .foregroundColor: color,
            .kern: size * 0.03,
        ])
        let box = text.size()
        let origin = CGPoint(x: align == .center ? p.x - box.width / 2 : p.x, y: p.y - box.height / 2)
        UIGraphicsPushContext(cg)
        text.draw(at: origin)
        UIGraphicsPopContext()
    }
}
