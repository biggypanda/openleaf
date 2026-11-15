import SwiftUI
import PencilKit

/// Kalem rengi: 24 bitlik herhangi bir RGB değeri (açık tema değeri; PencilKit koyu temada kendisi uyarlar).
/// `@AppStorage` için ham değeri Int olarak saklanır.
struct PenColor: Hashable, RawRepresentable {
    var rgb: UInt32

    init(rgb: UInt32) { self.rgb = rgb & 0xFFFFFF }
    init?(rawValue: Int) { self.init(rgb: UInt32(truncatingIfNeeded: rawValue)) }
    var rawValue: Int { Int(rgb) }

    static let ink = PenColor(rgb: 0x1E2321)
    static let indigo = PenColor(rgb: 0x2E4A7A)
    static let green = PenColor(rgb: 0x2F6B4F)
    static let wine = PenColor(rgb: 0x7A2E42)
    static let ochre = PenColor(rgb: 0xB98A2E)

    /// Uygulamanın ilk beş rengi; sık kullanılanlar ilk açılışta bunlardır
    static let defaults: [PenColor] = [.ink, .indigo, .green, .wine, .ochre]

    /// Eski sürümde renk 0–4 arası bir sıra numarası olarak "kalem.renk" anahtarında duruyordu
    static var initial: PenColor {
        let old = UserDefaults.standard.object(forKey: "kalem.renk") as? Int ?? 0
        return defaults.indices.contains(old) ? defaults[old] : .ink
    }

    var ui: UIColor { UIColor(hex: rgb) }

    /// Arayüzde gösterilen renk: koyu temada sayfada görünecek olan eşdeğer
    var swatch: Color {
        if let dark = Self.curatedDark[rgb] {
            return Color(uiColor: .dyn(rgb, dark))
        }
        let light = ui
        let dark = PKInkingTool.convertColor(light, from: .light, to: .dark)
        return Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// İlk beş rengin elle seçilmiş koyu tema karşılıkları
    private static let curatedDark: [UInt32: UInt32] = [
        0x1E2321: 0xEDE8DB, 0x2E4A7A: 0x8FAEE0, 0x2F6B4F: 0x8CC9A5, 0x7A2E42: 0xE0899F, 0xB98A2E: 0xE3BB5A,
    ]

    var hex: String { String(format: "#%06X", rgb) }

    init?(hex text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(rgb: v)
    }

    var name: String {
        switch rgb {
        case 0x1E2321: String(localized: "Mürekkep")
        case 0x2E4A7A: String(localized: "Çivit")
        case 0x2F6B4F: String(localized: "Yeşil")
        case 0x7A2E42: String(localized: "Şarap")
        case 0xB98A2E: String(localized: "Hardal")
        default: String(localized: "Renk \(hex)")
        }
    }

    // MARK: HSV

    init(hue h: Double, saturation s: Double, brightness v: Double) {
        func f(_ n: Double) -> UInt32 {
            let k = (n + h / 60).truncatingRemainder(dividingBy: 6)
            let x = v - v * s * max(min(k, 4 - k, 1), 0)
            return UInt32((min(max(x, 0), 1) * 255).rounded())
        }
        self.init(rgb: f(5) << 16 | f(3) << 8 | f(1))
    }

    var hsv: (h: Double, s: Double, v: Double) {
        let r = Double(rgb >> 16 & 0xFF) / 255, g = Double(rgb >> 8 & 0xFF) / 255, b = Double(rgb & 0xFF) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }
}

/// Sık kullanılan (5 yuva) ve son kullanılan (en çok 8) renkler; `@AppStorage` metinleri olarak saklanır.
enum PenPalette {
    static let favoritesKey = "kalem.renkler.sik"
    static let recentsKey = "kalem.renkler.son"
    static let slots = 5
    static let recentLimit = 8

    static func decode(_ raw: String) -> [PenColor] {
        raw.split(separator: ",").compactMap { UInt32($0, radix: 16).map(PenColor.init(rgb:)) }
    }

    static func encode(_ colors: [PenColor]) -> String {
        colors.map { String(format: "%06X", $0.rgb) }.joined(separator: ",")
    }

    /// Kayıt yoksa ya da bozuksa ilk beş renk
    static func favorites(_ raw: String) -> [PenColor] {
        let list = decode(raw)
        return list.count == slots ? list : PenColor.defaults
    }

    static func replacing(_ raw: String, slot: Int, with c: PenColor) -> String {
        var list = favorites(raw)
        guard list.indices.contains(slot) else { return raw }
        list[slot] = c
        return encode(list)
    }

    /// Rengi listenin başına alır; sık kullanılanlarda olan renkler son kullanılanlara eklenmez
    static func pushingRecent(_ raw: String, _ c: PenColor, favorites: [PenColor]) -> String {
        guard !favorites.contains(c) else { return raw }
        return encode(Array(([c] + decode(raw).filter { $0 != c }).prefix(recentLimit)))
    }
}

// MARK: - Renk paneli

/// 16,7 milyon renkten seçim: ızgara, spektrum ve hex kodu.
/// `slot` verilirse o sık kullanılan rengin yerine yeni renk konur.
struct ColorPanel: View {
    @Binding var color: PenColor
    var slot: Int?
    var onBack: () -> Void

    @AppStorage(PenPalette.favoritesKey) private var favoritesRaw = ""
    @AppStorage(PenPalette.recentsKey) private var recentsRaw = ""
    @State private var h = 0.0
    @State private var s = 0.0
    @State private var v = 0.0
    @State private var grid = false
    @State private var hexText = ""
    @State private var hexInvalid = false
    @State private var choosingSlot = false
    @FocusState private var hexFocused: Bool

    private var picked: PenColor { PenColor(hue: h, saturation: s, brightness: v) }
    private var original: PenColor { slot.map { PenPalette.favorites(favoritesRaw)[$0] } ?? color }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Text(slot == nil ? String(localized: "Renk seç") : String(localized: "Rengi değiştir"))
                    .font(.headline)
                HStack {
                    Button(action: onBack) {
                        Label("Kalem", systemImage: "chevron.left").font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Y.accent)
                    Spacer()
                }
            }

            Picker("Görünüm", selection: $grid) {
                Text("Izgara").tag(true)
                Text("Spektrum").tag(false)
            }
            .pickerStyle(.segmented)

            if grid { gridView } else { spectrum }

            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    Rectangle().fill(original.swatch).accessibilityLabel("Önceki renk")
                    Rectangle().fill(picked.swatch).accessibilityLabel("Yeni renk")
                }
                .frame(width: 68, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Y.line))

                Text(verbatim: "Hex").font(.caption).foregroundStyle(Y.ink3)
                TextField(text: $hexText, prompt: Text(verbatim: "#2E4A7A")) { Text(verbatim: "Hex") }
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .focused($hexFocused)
                    .padding(.horizontal, 8)
                    .frame(width: 104, height: 34)
                    .background(Y.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(hexInvalid ? Y.danger : Y.line))
                    .onChange(of: hexText) { _, t in applyHex(t) }
                    .onSubmit { applyHex(hexText, final: true) }
                    .accessibilityLabel("Renk kodu")
            }
            if hexInvalid {
                Text("Geçersiz renk kodu. Örnek: #2E4A7A").font(.footnote).foregroundStyle(Y.danger)
            }

            if choosingSlot {
                slotChooser
            } else {
                HStack(spacing: 10) {
                    if slot == nil {
                        Button { choosingSlot = true } label: {
                            Label("Sık kullanılanlara ekle", systemImage: "star")
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer(minLength: 0)
                    Button(slot == nil ? String(localized: "Kullan") : String(localized: "Kaydet")) { commit() }
                        .buttonStyle(.borderedProminent)
                }
                .tint(Y.accent)
                .font(.subheadline)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .onAppear { load(original) }
    }

    // MARK: Parçalar

    private var spectrum: some View {
        VStack(spacing: 14) {
            GeometryReader { g in
                ZStack {
                    LinearGradient(colors: [.white, Color(hue: h / 360, saturation: 1, brightness: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    Circle()
                        .fill(Color(uiColor: picked.ui))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                        .position(x: s * g.size.width, y: (1 - v) * g.size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    s = min(max(d.location.x / g.size.width, 0), 1)
                    v = 1 - min(max(d.location.y / g.size.height, 0), 1)
                    syncHex()
                })
            }
            .frame(height: 170)
            .accessibilityElement()
            .accessibilityLabel("Doygunluk ve parlaklık")
            .accessibilityValue(picked.hex)
            .accessibilityAdjustableAction { dir in
                v = min(max(v + (dir == .increment ? 0.05 : -0.05), 0), 1); syncHex()
            }

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(LinearGradient(
                        colors: stride(from: 0.0, through: 1.0, by: 1.0 / 6).map { Color(hue: $0, saturation: 1, brightness: 1) },
                        startPoint: .leading, endPoint: .trailing))
                    Circle()
                        .fill(Color(hue: h / 360, saturation: 1, brightness: 1))
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.35), radius: 1.5)
                        .position(x: h / 360 * g.size.width, y: g.size.height / 2)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { d in
                    h = min(max(d.location.x / g.size.width, 0), 0.9999) * 360
                    syncHex()
                })
            }
            .frame(height: 24)
            .accessibilityElement()
            .accessibilityLabel("Renk tonu")
            .accessibilityValue("\(Int(h.rounded()))°")
            .accessibilityAdjustableAction { dir in
                h = (h + (dir == .increment ? 10 : 350)).truncatingRemainder(dividingBy: 360); syncHex()
            }
        }
    }

    /// İlk satır griler, altında 12 ton × 5 açıklık
    private static let gridColors: [PenColor] = {
        let hues: [Double] = [0, 25, 45, 60, 95, 145, 175, 200, 220, 255, 285, 330]
        let sat: [Double] = [0.25, 0.5, 0.75, 0.9, 0.85]
        let bri: [Double] = [1, 0.95, 0.85, 0.62, 0.38]
        var out = (0..<12).map { PenColor(hue: 0, saturation: 0, brightness: 1 - Double($0) / 11) }
        for row in 0..<5 {
            out += hues.map { PenColor(hue: $0, saturation: sat[row], brightness: bri[row]) }
        }
        return out
    }()

    private var gridView: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 12), spacing: 2) {
            ForEach(Self.gridColors, id: \.self) { c in
                Button { load(c) } label: {
                    Rectangle().fill(Color(uiColor: c.ui))
                        .frame(height: 26)
                        .overlay(Rectangle().strokeBorder(c == picked ? Y.accent : .clear, lineWidth: 2.5))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(c.name)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(height: 170, alignment: .top)
    }

    private var slotChooser: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Hangi rengin yerine konsun?").font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                ForEach(Array(PenPalette.favorites(favoritesRaw).enumerated()), id: \.offset) { i, c in
                    Button {
                        favoritesRaw = PenPalette.replacing(favoritesRaw, slot: i, with: picked)
                        color = picked
                        choosingSlot = false
                        onBack()
                    } label: {
                        Circle().fill(c.swatch).frame(width: 34, height: 34)
                            .overlay(Circle().strokeBorder(Y.line))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "\(c.name) yerine"))
                }
                Spacer(minLength: 0)
                Button("Vazgeç") { choosingSlot = false }
                    .font(.subheadline)
                    .foregroundStyle(Y.accent)
            }
        }
    }

    // MARK: Davranış

    private func load(_ c: PenColor) {
        let x = c.hsv
        // Gri seçilince ton çubuğu yerinde kalsın
        if x.s > 0 { h = x.h }
        s = x.s; v = x.v
        syncHex()
    }

    private func syncHex() {
        guard !hexFocused else { return }
        hexText = picked.hex
        hexInvalid = false
    }

    private func applyHex(_ t: String, final: Bool = false) {
        guard hexFocused || final else { return }
        if let c = PenColor(hex: t) {
            hexInvalid = false
            let x = c.hsv
            if x.s > 0 { h = x.h }
            s = x.s; v = x.v
        } else {
            let digits = t.filter { $0 != "#" && !$0.isWhitespace }.count
            hexInvalid = final || digits >= 6
        }
    }

    private func commit() {
        if hexFocused, PenColor(hex: hexText) == nil { hexInvalid = true; return }
        let c = picked
        if let slot {
            favoritesRaw = PenPalette.replacing(favoritesRaw, slot: slot, with: c)
        } else {
            recentsRaw = PenPalette.pushingRecent(recentsRaw, c, favorites: PenPalette.favorites(favoritesRaw))
        }
        color = c
        onBack()
    }
}
