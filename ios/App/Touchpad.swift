import SwiftUI
import UIKit

enum PadInput {
    case move, scroll, click
}

struct Touchpad: UIViewRepresentable {
    let send: (PadInput, CGPoint) -> Void
    func makeUIView(context: Context) -> PadView {
        let view = PadView()
        view.send = send
        return view
    }
    func updateUIView(_ view: PadView, context: Context) {
        view.send = send
        view.isUserInteractionEnabled = context.environment.isEnabled
    }
}

final class PadView: UIView {
    var send: ((PadInput, CGPoint) -> Void)?
    private var fingers = 0
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag))
    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        pan.maximumNumberOfTouches = 2
        addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(click))
        tap.require(toFail: pan)
        addGestureRecognizer(tap)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        var ancestor = superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView {
                scroll.panGestureRecognizer.require(toFail: pan)
                break
            }
            ancestor = view.superview
        }
    }
    @objc private func click() {
        UISelectionFeedbackGenerator().selectionChanged()
        send?(.click, .zero)
    }
    @objc private func drag() {
        let count = pan.numberOfTouches
        let delta = pan.translation(in: self)
        pan.setTranslation(.zero, in: self)
        if pan.state == .began { fingers = count }
        guard pan.state == .changed || pan.state == .began else { return }
        guard count == fingers else { fingers = count; return }
        let scale: CGFloat = count == 2 ? -1.1 : 3.3
        send?(count == 2 ? .scroll : .move, CGPoint(x: delta.x * scale, y: delta.y * scale))
    }
}
