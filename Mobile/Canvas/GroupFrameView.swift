import QueenBeeCore
import UIKit

/// A group of cards on the canvas. Unfolded, it is a named frame drawn behind its cards. Folded, it is one
/// small card that stands in for all of them. The Mac's `GroupFrameView`.
final class GroupFrameView: UIView {
    private(set) var look: GroupLook
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    var zoom: CGFloat = 1 { didSet { if zoom != oldValue { setNeedsLayout() } } }

    init(look: GroupLook) {
        self.look = look
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        layer.cornerRadius = Theme.Radius.card
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.textColor = Theme.ink
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)
        addSubview(detailLabel)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: GroupFrameView, _) in view.restyle() }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Selects the group, when VoiceOver's double tap lands on it.
    var onActivate: (() -> Void)?

    override func accessibilityActivate() -> Bool {
        onActivate?()
        return onActivate != nil
    }

    /// VoiceOver is given the name strip, like a finger: the frame's inside belongs to its cards.
    override var accessibilityFrame: CGRect {
        get { superview.map { UIAccessibility.convertToScreenCoordinates(handle, in: $0) } ?? super.accessibilityFrame }
        set {}
    }

    /// The part a tap selects the group by: the name strip, or the whole card when folded. The frame's
    /// inside is empty canvas.
    var handle: CGRect {
        look.group.isFolded ? frame
            : CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: CanvasGeometry.groupTitleHeight * CanvasGeometry.groupScale(for: zoom))
    }

    func update(_ new: GroupLook, frame target: CGRect) {
        look = new
        if frame != target { frame = target }
        nameLabel.text = new.group.name
        detailLabel.text = new.detail
        accessibilityLabel = new.group.isFolded ? "Group \(new.group.name), folded" : "Group \(new.group.name)"
        accessibilityValue = new.detail
        accessibilityTraits = new.isSelected ? [.button, .selected] : .button
        restyle()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = CanvasGeometry.groupScale(for: zoom)
        if look.group.isFolded {
            // The folded card is a fixed size, so its type only grows as far as the card has room for.
            let grown = min(scale, 1.7)
            nameLabel.font = Theme.mono(Theme.Size.body * grown, .medium)
            detailLabel.font = Theme.mono(Theme.Size.caption * grown)
            let nameHeight = ceil(nameLabel.intrinsicContentSize.height), detailHeight = ceil(detailLabel.intrinsicContentSize.height)
            let top = max(4, (bounds.height - nameHeight - detailHeight - 2) / 2)
            nameLabel.frame = CGRect(x: 12, y: top, width: bounds.width - 24, height: nameHeight)
            detailLabel.frame = CGRect(x: 12, y: top + nameHeight + 2, width: bounds.width - 24, height: detailHeight)
        } else {
            nameLabel.font = Theme.mono(Theme.Size.body * scale, .medium)
            detailLabel.font = Theme.mono(Theme.Size.caption * scale)
            let strip = CanvasGeometry.groupTitleHeight * scale
            let name = nameLabel.intrinsicContentSize, detail = detailLabel.intrinsicContentSize
            nameLabel.frame = CGRect(x: 10 * scale, y: (strip - ceil(name.height)) / 2, width: min(ceil(name.width), bounds.width * 0.6), height: ceil(name.height))
            detailLabel.frame = CGRect(x: nameLabel.frame.maxX + 8 * scale, y: (strip - ceil(detail.height)) / 2,
                                       width: max(0, bounds.width - nameLabel.frame.maxX - 18 * scale), height: ceil(detail.height))
        }
    }

    private func restyle() {
        let folded = look.group.isFolded, tone = look.tone
        backgroundColor = folded ? (tone == .fail ? Theme.failTint : tone == .live ? Theme.liveTint : Theme.surface)
                                 : Theme.ink.withAlphaComponent(0.035)
        let edge = look.isSelected ? Theme.select : tone == .fail ? Theme.failInk : tone == .live ? Theme.live : folded ? Theme.ink : Theme.inkSecondary
        layer.borderColor = edge.cg(in: self)
        layer.borderWidth = look.isSelected ? Theme.Stroke.selected : Theme.Stroke.card
        detailLabel.textColor = tone == .live ? Theme.liveInk : tone == .fail ? Theme.failInk : Theme.inkSecondary
    }
}
