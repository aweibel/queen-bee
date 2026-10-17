import QueenBeeCore
import UIKit

/// The browser half of an agent card on the canvas: the Mac's thin bar, with back, forward, reload and the
/// address, and under it the newest picture of the page, drawn at the card's size as the Mac draws it. The
/// Mac's `BrowserPaneView`. It takes no touches: a tap on the card selects it, and the mark at the bar's end
/// opens the browser full screen, where the page can be used.
final class BrowserHalfView: UIView {
    /// The Mac's own bar height, so the page is the same size here as there.
    static let barHeight: CGFloat = 26
    static let expandSize: CGFloat = 14

    private let bar = UIView()
    private let barRule = UIView()
    private let back = BrowserHalfView.icon("chevron.left")
    private let forward = BrowserHalfView.icon("chevron.right")
    private let reload = BrowserHalfView.icon("arrow.clockwise")
    private let address = UILabel()
    private let expand = BrowserHalfView.icon("arrow.up.left.and.arrow.down.right", weight: .semibold)
    let page = UIImageView()
    private let notice = UILabel()
    /// What the notice's button offers, drawn as the Mac's button is. It is pressed in the full-screen view.
    private let offer = UILabel()
    private(set) var shown: (page: RemoteBrowserPage?, picture: BrowserPicture?) = (nil, nil)

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = Theme.surface
        bar.backgroundColor = Theme.bar
        barRule.backgroundColor = Theme.hairline
        addSubview(page)
        addSubview(bar)
        addSubview(barRule)
        [back, forward, reload, expand].forEach(bar.addSubview)
        address.font = Theme.mono(Theme.Size.caption)
        address.textColor = Theme.ink
        address.lineBreakMode = .byTruncatingTail
        bar.addSubview(address)
        page.contentMode = .scaleAspectFit
        // A page is drawn on white whatever the app's appearance, as it is on the Mac.
        page.backgroundColor = .white
        page.clipsToBounds = true
        notice.font = Theme.sans(Theme.Size.body)
        notice.textColor = Theme.inkSecondary
        notice.textAlignment = .center
        notice.numberOfLines = 0
        addSubview(notice)
        offer.font = Theme.mono(Theme.Size.body)
        offer.textColor = Theme.ink
        offer.textAlignment = .center
        offer.layer.cornerRadius = Theme.Radius.card
        offer.layer.borderWidth = Theme.Stroke.card
        offer.backgroundColor = Theme.surface
        addSubview(offer)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: BrowserHalfView, _) in view.offer.layer.borderColor = Theme.ink.cg(in: view) }
        offer.layer.borderColor = Theme.ink.cg(in: self)
        show(page: nil, picture: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func icon(_ symbol: String, weight: UIImage.SymbolWeight = .medium) -> UIImageView {
        let view = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: weight)))
        view.contentMode = .center
        view.tintColor = Theme.ink
        return view
    }

    /// Where the page is drawn, in this view's points.
    var pageFrame: CGRect { page.frame }

    /// Where the mark that opens the browser full screen is, in this view's points.
    var expandFrame: CGRect { expand.frame }

    func show(page new: RemoteBrowserPage?, picture: BrowserPicture?) {
        shown = (new, picture)
        let state = new ?? RemoteBrowserPage()
        address.text = state.url.isEmpty ? " " : state.url
        back.alpha = state.canGoBack ? 1 : 0.35
        forward.alpha = state.canGoForward ? 1 : 0.35
        let said = state.notice
        notice.text = said?.words
        notice.isHidden = said == nil
        offer.text = said?.offer.map { "  \($0.title)  " }
        offer.isHidden = said?.offer == nil
        // A picture left over from before the browser stopped would look live when it isn't.
        page.image = said == nil ? picture?.image : nil
        page.backgroundColor = said == nil ? .white : Theme.surface
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = Self.barHeight
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
        barRule.frame = CGRect(x: 0, y: h, width: bounds.width, height: 1)
        var x: CGFloat = 4
        for icon in [back, forward, reload] {
            icon.frame = CGRect(x: x, y: 2, width: 22, height: h - 4)
            x += 22
        }
        let size = Self.expandSize
        expand.frame = CGRect(x: bounds.width - 8 - size, y: (h - size) / 2, width: size, height: size)
        address.frame = CGRect(x: x + 6, y: 0, width: max(0, expand.frame.minX - x - 14), height: h)
        page.frame = CGRect(x: 0, y: h + 1, width: bounds.width, height: max(0, bounds.height - h - 1))
        let width = min(page.frame.width - 32, 300)
        let wanted = notice.sizeThatFits(CGSize(width: width, height: 200))
        let button = offer.isHidden ? CGSize.zero : offer.sizeThatFits(CGSize(width: width, height: 40))
        let total = wanted.height + (offer.isHidden ? 0 : button.height + 14)
        let top = page.frame.minY + max(8, (page.frame.height - total) / 2)
        notice.frame = CGRect(x: page.frame.midX - width / 2, y: top, width: width, height: wanted.height)
        offer.frame = CGRect(x: page.frame.midX - button.width / 2, y: top + wanted.height + 10, width: button.width, height: button.height + 4)
    }
}
