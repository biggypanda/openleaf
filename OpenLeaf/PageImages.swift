import SwiftUI
import UIKit

// MARK: - Model

/// Sayfaya eklenmiş resim. Konum ve boyut kanonik sayfa koordinatlarında; dosya defter klasöründe durur.
struct PageImage: Identifiable, Codable, Equatable {
    var id = UUID()
    /// Defter klasöründeki dosya adı ("img-<uuid>.jpg")
    var file: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: w, height: h) }
        set { x = newValue.minX; y = newValue.minY; w = newValue.width; h = newValue.height }
    }

    /// Köşeden küçültürken en küçük genişlik (kanonik)
    static let minWidth: Double = 60
}

// MARK: - Dosyalar

enum ImageStore {
    /// NotebookStore'un varsayılan kökü ile aynı yer
    static func url(_ notebook: UUID, _ file: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenLeaf/Defterler", isDirectory: true)
            .appendingPathComponent(notebook.uuidString, isDirectory: true)
            .appendingPathComponent(file)
    }

    private static let cache = NSCache<NSString, UIImage>()

    /// Yeni eklenen resim: dosya henüz arka planda yazılırken de hemen gösterilebilsin
    static func remember(_ notebook: UUID, _ file: String, _ image: UIImage) {
        cache.setObject(image, forKey: "\(notebook)/\(file)" as NSString)
    }

    static func image(_ notebook: UUID, _ file: String) -> UIImage? {
        let key = "\(notebook)/\(file)" as NSString
        if let img = cache.object(forKey: key) { return img }
        guard let img = UIImage(contentsOfFile: url(notebook, file).path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    /// Büyük fotoğrafları küçültüp JPEG'e çevirir (uzun kenar en fazla 2048 piksel)
    static func prepare(_ image: UIImage) -> (data: Data, size: CGSize)? {
        let maxSide: CGFloat = 2048
        let s = image.size
        guard s.width > 0, s.height > 0 else { return nil }
        let k = min(1, maxSide / max(s.width * image.scale, s.height * image.scale))
        let target = CGSize(width: (s.width * image.scale * k).rounded(), height: (s.height * image.scale * k).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = resized.jpegData(compressionQuality: 0.85) else { return nil }
        return (data, target)
    }
}

extension Library {
    /// Resim dosyasını defter klasörüne yazar, dosya adını döndürür
    func saveImageFile(_ id: UUID, data: Data) -> String {
        let name = "img-\(UUID().uuidString).jpg"
        store.createDir(id)
        store.writeFile(data, to: store.dir(id).appendingPathComponent(name))
        return name
    }

    func setImages(_ id: UUID, _ page: UUID, _ images: [PageImage]) {
        update(id) { nb in
            if let i = nb.pages.firstIndex(where: { $0.id == page }) { nb.pages[i].images = images.isEmpty ? nil : images }
            nb.modified = Date()
        }
        cleanupImages(id)
        scheduleThumbnail(id)
    }

    /// Hiçbir sayfanın kullanmadığı resim dosyalarını siler (çoğaltılan sayfalar aynı dosyayı paylaşabilir)
    func cleanupImages(_ id: UUID) {
        guard let nb = notebooks.first(where: { $0.id == id }) else { return }
        let used = Set(nb.pages.flatMap { $0.pageImages.map(\.file) })
        let dir = store.dir(id)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasPrefix("img-") && !used.contains(name) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

// MARK: - Seçili resim: taşı, köşeden boyutlandır, sil

final class ImageSelectionView: UIView {
    var onMove: ((CGRect) -> Void)?
    var onMoveEnded: (() -> Void)?
    var onDelete: (() -> Void)?

    private let border = CAShapeLayer()
    private let handle = UIView()
    private let handleDot = UIView()
    private let menuButton = UIButton(type: .system)
    private var startFrame: CGRect = .zero
    private lazy var resizePan = UIPanGestureRecognizer(target: self, action: #selector(resize(_:)))
    /// Çerçeve ile resim arası boşluk
    static let pad: CGFloat = 6

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        border.fillColor = UIColor.clear.cgColor
        border.strokeColor = UIColor(hex: 0x24483F).cgColor
        border.lineWidth = 2
        border.lineDashPattern = [6, 4]
        layer.addSublayer(border)

        // Dokunma alanı 36 pt, görünen nokta 18 pt
        handle.backgroundColor = .clear
        handleDot.backgroundColor = UIColor(hex: 0x24483F)
        handleDot.layer.cornerRadius = 9
        handleDot.layer.borderColor = UIColor.white.cgColor
        handleDot.layer.borderWidth = 2
        handleDot.isUserInteractionEnabled = false
        handle.addSubview(handleDot)
        handle.accessibilityLabel = String(localized: "Resmi boyutlandır")
        handle.addGestureRecognizer(resizePan)
        addSubview(handle)

        menuButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)), for: .normal)
        menuButton.tintColor = UIColor(hex: 0x24483F)
        menuButton.backgroundColor = UIColor(hex: 0xFBF9F4)
        menuButton.layer.cornerRadius = 15
        menuButton.layer.borderWidth = 1
        menuButton.layer.borderColor = UIColor.black.withAlphaComponent(0.12).cgColor
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = String(localized: "Resim seçenekleri")
        menuButton.menu = UIMenu(children: [
            UIAction(title: String(localized: "Resmi sil"), image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.onDelete?()
            }
        ])
        addSubview(menuButton)

        let movePan = UIPanGestureRecognizer(target: self, action: #selector(dragImage(_:)))
        movePan.require(toFail: resizePan)
        addGestureRecognizer(movePan)
        accessibilityLabel = String(localized: "Seçili resim; sürükleyerek taşıyın")
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        border.frame = bounds
        border.path = UIBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)).cgPath
        handle.frame = CGRect(x: bounds.maxX - 23, y: bounds.maxY - 23, width: 36, height: 36)
        handleDot.frame = CGRect(x: 9, y: 9, width: 18, height: 18)
        menuButton.frame = CGRect(x: bounds.maxX - 36, y: bounds.minY + 6, width: 30, height: 30)
    }

    /// Tutamaç çerçevenin biraz dışına taşıyor; ona da dokunulabilsin
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -16, dy: -16).contains(point)
    }

    /// Resmin ekrandaki çerçevesi (boşluk hariç)
    var imageFrame: CGRect { frame.insetBy(dx: Self.pad, dy: Self.pad) }

    @objc private func dragImage(_ g: UIPanGestureRecognizer) {
        guard let sv = superview else { return }
        switch g.state {
        case .began: startFrame = imageFrame
        case .changed:
            let t = g.translation(in: sv)
            onMove?(startFrame.offsetBy(dx: t.x, dy: t.y))
        default: onMoveEnded?()
        }
    }

    /// Sağ alt köşeden, oran korunarak boyutlandırma
    @objc private func resize(_ g: UIPanGestureRecognizer) {
        guard let sv = superview else { return }
        switch g.state {
        case .began: startFrame = imageFrame
        case .changed:
            let t = g.translation(in: sv)
            let ratio = startFrame.height / max(startFrame.width, 1)
            let w = max(40, startFrame.width + t.x)
            onMove?(CGRect(x: startFrame.minX, y: startFrame.minY, width: w, height: w * ratio))
        default: onMoveEnded?()
        }
    }
}

// MARK: - Kamera

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = .camera
        p.delegate = context.coordinator
        return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ p: CameraPicker) { parent = p }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.onImage(img) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
