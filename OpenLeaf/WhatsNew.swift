import SwiftUI

/// Güncelleyen kullanıcıya bir kez gösterilen "Yenilikler" penceresi.
/// Yeni sürümde yeni özellik tanıtılacaksa `version` ile `items` değiştirilir; aynı sürüm bir daha gösterilmez.
/// Yeni kuranlar bunu görmez: onlara ilk açılış tanıtımı çıkar.
struct WhatsNew: View {
    /// Bu pencerenin tanıttığı sürüm (uygulama sürümüyle aynı olmak zorunda değil; yamada değişmez)
    static let version = "1.1.3"

    /// "Defterlerimi taşı": taşıma rehberini açar
    var onMigrate: () -> Void
    @Environment(\.dismiss) private var dismiss

    private struct Item: Identifiable {
        let id = UUID()
        let symbol: String
        let title: String
        let text: String
    }

    private var items: [Item] {
        [
            Item(symbol: "arrow.right.doc.on.clipboard",
                 title: String(localized: "Başka uygulamadan taşı"),
                 text: String(localized: "GoodNotes, Notability ya da PDF veren her uygulamadan tüm defterlerini tek seferde getir; klasörlerin korunur.")),
            Item(symbol: "pencil",
                 title: String(localized: "Defteri yeniden adlandır"),
                 text: String(localized: "Bir deftere basılı tut ve Yeniden adlandır'ı seç.")),
            Item(symbol: "lock",
                 title: String(localized: "Resmi yerine kilitle"),
                 text: String(localized: "Sayfadaki resmi kilitle; üstüne yazarken yanlışlıkla kaymasın.")),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    Text("OpenLeaf'te yenilikler")
                        .font(Y.serif(.title, .semibold))
                        .foregroundStyle(Y.ink)
                        .multilineTextAlignment(.center)
                        .padding(.top, 44)
                        .padding(.bottom, 32)
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(items) { item in
                            HStack(alignment: .top, spacing: 16) {
                                Image(systemName: item.symbol)
                                    .font(.title2)
                                    .foregroundStyle(Y.accent)
                                    .frame(width: 40)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.headline)
                                        .foregroundStyle(Y.ink)
                                    Text(item.text)
                                        .font(.body)
                                        .foregroundStyle(Y.ink2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
            }

            VStack(spacing: 6) {
                Button { dismiss() } label: {
                    Text("Devam")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(Y.accent, in: Capsule())
                        .foregroundStyle(Y.accentInk)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button("Defterlerimi taşı") {
                    dismiss()
                    onMigrate()
                }
                .font(.body)
                .frame(height: 40)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 22)
        }
        .tint(Y.accent)
        .background(Y.surface)
    }
}
