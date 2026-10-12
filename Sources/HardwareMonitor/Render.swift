import AppKit

private func rgba(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

/// The colour tokens per appearance (GlanceBar's `Style`, with the artifact's values), with Increase Contrast and
/// Reduce Transparency (DD-9). Resolved per draw.
struct Style: Equatable {
    var dark = false
    var contrast = false
    var reduceTransparency = false

    /// Seam: snapshot tests pin the drawing appearance; nil in production (the drawing appearance is used).
    static var appearanceOverride: NSAppearance?

    static func current(for appearance: NSAppearance) -> Style {
        Style(dark: (appearanceOverride ?? appearance).bestMatch(from: [.aqua, .darkAqua]) == .darkAqua,
              contrast: Env.workspace.accessibilityDisplayShouldIncreaseContrast,
              reduceTransparency: Env.workspace.accessibilityDisplayShouldReduceTransparency)
    }

    var fg: NSColor { dark ? rgba(0xf5, 0xf5, 0xf7) : rgba(0x1d, 0x1d, 0x1f) }
    /// GlanceBar's 0.80 / 0.78 for the see-through bar; Increase Contrast draws dim text at full strength in the menu
    /// bar, as the artifact's States demo shows (deviation 11).
    var dim: NSColor { contrast ? fg : dark ? rgba(245, 245, 247, 0.80) : rgba(29, 29, 31, 0.78) }
    var track: NSColor { dark ? rgba(255, 255, 255, contrast ? 0.32 : 0.2) : rgba(0, 0, 0, contrast ? 0.26 : 0.14) }
    /// The open-panel item highlight: grey (50 %) at 22 % (deviation 9, DD-14).
    var highlight: NSColor { rgba(127, 127, 127, 0.22) }

    /// Text in a level's colour. Light warning text is #9A5A00 (about 5.5 : 1 on white, deviation 2).
    func text(_ level: Level) -> NSColor {
        switch level {
        case .normal: fg
        case .warning: dark ? rgba(0xff, 0xb3, 0x40) : rgba(0x9a, 0x5a, 0x00)
        case .critical: crit
        }
    }

    /// Fills (the pressure bar) keep #C77700 in light (deviation 2).
    func fill(_ level: Level) -> NSColor {
        switch level {
        case .normal: dim
        case .warning: dark ? rgba(0xff, 0xb3, 0x40) : rgba(0xc7, 0x77, 0x00)
        case .critical: crit
        }
    }

    private var crit: NSColor { dark ? rgba(0xff, 0x5a, 0x4f) : rgba(0xd9, 0x2d, 0x20) }

    // MARK: Panel tokens (UI/UX Wireframes → Hover panel, deviation 9; DD-9: Increase Contrast raises dim, track and
    // sep; Reduce Transparency makes the background solid)

    var panelDim: NSColor { dark ? rgba(245, 245, 247, contrast ? 0.92 : 0.72) : rgba(29, 29, 31, contrast ? 0.92 : 0.66) }
    var panelTrack: NSColor { dark ? rgba(255, 255, 255, contrast ? 0.32 : 0.16) : rgba(0, 0, 0, contrast ? 0.26 : 0.10) }
    var sep: NSColor { dark ? rgba(255, 255, 255, contrast ? 0.40 : 0.12) : rgba(0, 0, 0, contrast ? 0.40 : 0.10) }
    var tint: NSColor { dark ? rgba(255, 255, 255, 0.07) : rgba(0, 0, 0, 0.045) }
    var panel: NSColor { dark ? rgba(36, 38, 48, reduceTransparency ? 1 : 0.94) : rgba(250, 250, 252, reduceTransparency ? 1 : 0.97) }
}

/// A pure value describing the status image (R-16): only what the image shows, so it changes only when the drawn
/// content would. Drawn as the artifact's `item()` (UI/UX Wireframes → Status item image).
struct Glance: Equatable {
    var columns: [Column]
    var highlighted = false   // the open-panel item highlight (DD-14, Phase 2)
    var dev = false           // the Dev builds' "DEV" label (DD-14)
    var style = Style()       // the appearance the image was built for (DD-5)

    // MARK: Metrics

    static let height: CGFloat = 22
    private static let padding: CGFloat = 4, gap: CGFloat = 8, glyphSize: CGFloat = 13, glyphGap: CGFloat = 3
    private static let devFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    /// "DEV" baseline: GlanceBar's label baseline, cap height centred on y 11.
    private static let devBaseline: CGFloat = 15.6
    /// GlanceBar's proven value baselines (deviation 11), and the 3.5 pt bar centred on the bottom line's digits.
    private static let topLine: CGFloat = 10.4, bottomLine: CGFloat = 19.4, barY: CGFloat = 13.75
    private static let unitScale: CGFloat = 0.8, unitAlpha: CGFloat = 0.78
    /// The artifact's flex gap between the digits, the unit and the mark; the unit adds its 0.06 em margin.
    private static let runGap: CGFloat = 1.5

    private static func digits(_ v: Column.Value, top: Bool) -> NSFont {
        let weight: NSFont.Weight = switch v.level {
        case .critical: .bold
        case .warning: .semibold
        case .normal: top || v.strong ? .medium : .regular
        }
        return .monospacedDigitSystemFont(ofSize: 11, weight: weight)
    }
    private static let unitFont = NSFont.systemFont(ofSize: 11 * unitScale, weight: .regular)
    private static let markFont = NSFont.systemFont(ofSize: 9, weight: .heavy) // deviation 9: heavy `!`

    /// R-14: each slot is reserved at its widest realistic text including the critical mark, so the width never
    /// changes (deviation 11: these, not the artifact's "100%/100°/99W/1.8T").
    private static func slot(_ glyph: Column.Glyph) -> CGFloat {
        func w(_ text: String, _ unit: String, _ level: Level = .normal, strong: Bool = true, top: Bool = true) -> CGFloat {
            value(Column.Value(text: text, unit: unit, level: level, strong: strong), x: 0, line: 0, top: top, style: nil)
        }
        return switch glyph {
        case .cpu, .gpu: max(w("100", "%"), w("120", "°", .critical, strong: false, top: false))
        case .memory: max(w("100", "%", .critical), 22)
        case .power: max(w("188", "W"), w("8.8", "W"))
        case .disk: max(w("999", "G", .critical), w("9.9", "T", .critical), w("999", "G", strong: false, top: false),
                        w("9.9", "T", strong: false, top: false))
        }
    }
    private static let slots: [Column.Glyph: CGFloat] = Dictionary(uniqueKeysWithValues:
        [Column.Glyph.cpu, .gpu, .memory, .power, .disk].map { ($0, slot($0)) })

    /// The status image: non-template, 22 pt tall, drawn at draw time in the drawing appearance (DD-5), so each
    /// display's menu bar replica gets its own colours.
    func image() -> NSImage {
        let image = NSImage(size: NSSize(width: width, height: Self.height), flipped: true) { _ in
            self.draw(Style.current(for: NSAppearance.currentDrawing()))
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Drawing

    /// Draws the columns left to right in `style`.
    private func draw(_ style: Style) {
        if highlighted {
            style.highlight.setFill()
            NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: width, height: Self.height), xRadius: 5, yRadius: 5).fill()
        }
        var x = Self.padding
        if dev { x += Self.text("DEV", x, Self.devBaseline, Self.devFont, style.dim) + Self.gap }
        for col in columns {
            Self.glyph(col.glyph, in: CGRect(x: x, y: (Self.height - Self.glyphSize) / 2, width: Self.glyphSize, height: Self.glyphSize),
                       style.fg)
            if col.badge { // the BADGE bolt, 6 × 8.5, 3 pt beyond the glyph's right edge and 2.5 pt above its top
                Self.bolt(in: CGRect(x: x + Self.glyphSize + 3 - 6, y: (Self.height - Self.glyphSize) / 2 - 2.5,
                                     width: 6, height: 8.5), style.fg)
            }
            x += Self.glyphSize + Self.glyphGap
            Self.value(col.top, x: x, line: Self.topLine, top: true, style: style)
            switch col.bottom {
            case .value(let v): Self.value(v, x: x, line: Self.bottomLine, top: false, style: style)
            case let .bar(fill?, level):
                let bar = CGRect(x: x, y: Self.barY, width: 22, height: 3.5)
                style.track.setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.75, yRadius: 1.75).fill()
                if fill > 0 { // never narrower than its height, so the fill stays round
                    style.fill(level).setFill()
                    let w = max(bar.height, bar.width * CGFloat(min(fill, 100)) / 100)
                    NSBezierPath(roundedRect: CGRect(x: x, y: Self.barY, width: w, height: 3.5), xRadius: 1.75, yRadius: 1.75).fill()
                }
            case .bar(nil, _): Self.value(Metrics.missing, x: x, line: Self.bottomLine, top: false, style: style)
            }
            x += (Self.slots[col.glyph] ?? 0) + Self.gap
        }
    }

    /// 4 pt side padding, the optional "DEV" label, then each column (glyph, 3 pt, slot) 8 pt apart.
    var width: CGFloat {
        var x = Self.padding * 2
        if dev { x += Self.text("DEV", 0, 0, Self.devFont, nil) + Self.gap }
        for col in columns { x += Self.glyphSize + Self.glyphGap + (Self.slots[col.glyph] ?? 0) }
        x += Self.gap * CGFloat(max(0, columns.count - 1))
        return ceil(x)
    }

    /// One value: digits, the unit (0.8 em, regular, 78 % of the value's colour) and the heavy critical `!`, each
    /// centred on the digits' line box as the artifact's flex row; measures only when `style` is nil. Returns its width.
    @discardableResult
    private static func value(_ v: Column.Value, x: CGFloat, line: CGFloat, top: Bool, style: Style?) -> CGFloat {
        let font = digits(v, top: top)
        let color = style.map { s in v.level != .normal ? s.text(v.level) : v.strong ? s.fg : s.dim }
        let centre = line - (font.ascender + font.descender) / 2
        func baseline(_ f: NSFont) -> CGFloat { centre + (f.ascender + f.descender) / 2 }
        var w = text(v.text, x, line, font, color)
        if !v.unit.isEmpty {
            w += runGap + unitFont.pointSize * 0.06
            w += text(v.unit, x + w, baseline(unitFont), unitFont, color.map { $0.withAlphaComponent($0.alphaComponent * unitAlpha) })
        }
        if v.level == .critical {
            w += runGap
            w += text("!", x + w, baseline(markFont), markFont, color)
        }
        return w
    }

    /// Draws `s` with its baseline at `baseline` (flipped coordinates) when `color` is given; returns its width.
    @discardableResult
    private static func text(_ s: String, _ x: CGFloat, _ baseline: CGFloat, _ font: NSFont, _ color: NSColor?) -> CGFloat {
        let string = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color ?? .clear])
        if color != nil { string.draw(at: CGPoint(x: x, y: baseline - font.ascender)) }
        return string.size().width
    }

    // MARK: Glyphs

    /// The column glyphs, transcribed from the artifact's `SYM` (13-unit grid, top-left origin) and scaled to `rect`
    /// as the browser scales its viewBox: 1.4-unit strokes, round joins, butt caps, no fill except the gauge's hub.
    /// Disk stays the SF Symbol `internaldrive` (owner choice, 2026-10-12). Callers draw in flipped coordinates.
    static func glyph(_ g: Column.Glyph, in rect: CGRect, _ color: NSColor) {
        let k = rect.width / 13
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * k, y: rect.minY + y * k) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(origin: p(x, y), size: CGSize(width: w * k, height: h * k)) }
        let path = NSBezierPath()
        func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) {
            path.appendRoundedRect(box(x, y, w, h), xRadius: r * k, yRadius: r * k)
        }
        func lines(_ segments: [(CGFloat, CGFloat, CGFloat, CGFloat)]) {
            for (x0, y0, x1, y1) in segments { path.move(to: p(x0, y0)); path.line(to: p(x1, y1)) }
        }
        switch g {
        case .cpu:
            rounded(3, 3, 7, 7, 1)
            lines([(5, 1, 5, 3), (8, 1, 8, 3), (5, 10, 5, 12), (8, 10, 8, 12),
                   (1, 5, 3, 5), (1, 8, 3, 8), (10, 5, 12, 5), (10, 8, 12, 8)])
        case .gpu:
            rounded(1, 3, 11, 7, 1)
            path.appendOval(in: box(5 - 1.9, 6.5 - 1.9, 3.8, 3.8))
            lines([(8.6, 5, 8.6, 8), (10.4, 5, 10.4, 8), (3, 10, 3, 11.8), (6.5, 10, 6.5, 11.8)])
        case .memory:
            rounded(1, 4, 11, 5, 0.6)
            lines([(3, 9, 3, 11), (5.3, 9, 5.3, 11), (7.7, 9, 7.7, 11), (10, 9, 10, 11), (3.5, 6, 9.5, 6)])
        case .power:
            // Half circle over the top (y grows downward here, so 180° → 270° → 360° passes above the centre),
            // the needle up-right, and the hub dot (filled and stroked, as the SVG).
            path.move(to: p(1.5, 9.8))
            path.appendArc(withCenter: p(6.5, 9.8), radius: 5 * k, startAngle: 180, endAngle: 360, clockwise: false)
            lines([(6.5, 9.8, 9.2, 5.6)])
            let hub = NSBezierPath(ovalIn: box(6.5 - 0.7, 9.8 - 0.7, 1.4, 1.4))
            color.setFill()
            hub.fill()
            path.append(hub)
        case .disk:
            symbol("internaldrive", in: rect, color)
            return
        }
        path.lineWidth = 1.4 * k
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// The artifact's `BADGE`/`SW_BOLT` bolt (viewBox 6 × 9), filled, fitted into `rect` as `meet` does: uniform
    /// scale, centred.
    static func bolt(in rect: CGRect, _ color: NSColor) {
        let k = min(rect.width / 6, rect.height / 9)
        let o = CGPoint(x: rect.midX - 3 * k, y: rect.midY - 4.5 * k)
        let points: [(CGFloat, CGFloat)] = [(3.6, 0), (0, 5), (2.3, 5), (1.9, 9), (6, 3.6), (3.7, 3.6)]
        let path = NSBezierPath()
        var scaled = points.map { NSPoint(x: o.x + $0.0 * k, y: o.y + $0.1 * k) }
        path.appendPoints(&scaled, count: scaled.count) // the empty path makes the first a move
        path.close()
        color.setFill()
        path.fill()
    }

    /// An SF Symbol tinted `color`, aspect-fitted and centred in `rect` (only the disk glyph).
    private static func symbol(_ name: String, in rect: CGRect, _ color: NSColor) {
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let scale = min(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// MARK: - Hover panel (R-17, layout B)

/// A pure value of what the panel shows, so its views are rebuilt only when the content changes (R-19).
struct Panel: Equatable {
    var content: PanelContent
    var style: Style
}

/// A flipped view that draws through a closure: the panel's box, tiles and lists.
final class Drawn: NSView {
    var paint: (Drawn) -> Void = { _ in }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) { paint(self) }
}

/// The panel's content view (the artifact's `.panel`, layout B): a menu-material blur forced active (the app is never
/// active), then the box with the tint and the 2-2-1-1 tile grid. The view and its window are exactly the box; the
/// shadow is the window's native one, which never catches clicks (GlanceBar's approach).
final class PanelView: NSView {
    /// 354 content + 7 padding on each side (deviation 9), tiles 8 pt apart: half tiles 173 pt.
    static let content: CGFloat = 354, padding: CGFloat = 7, gap: CGFloat = 8
    static let width = content + 2 * padding, half = (content - gap) / 2

    let effect = NSVisualEffectView()
    let box = Drawn()
    private(set) var panel: Panel?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = NSImage(size: NSSize(width: 25, height: 25), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
            return true
        }
        effect.maskImage?.capInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        effect.maskImage?.resizingMode = .stretch
        addSubview(effect)
        addSubview(box)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Layout (UI/UX Wireframes → Hover panel)

    private enum Block {
        case tile(Tile)
        case lists([ProcessList])
        case footer(String)
    }

    /// Tile anatomy: 8 padding, 18 header, 4, 27 primary, 6 + 20 graphic slot + 6, 16 pt rows 2 apart, 8 padding.
    private static func tileHeight(_ t: Tile) -> CGFloat {
        8 + 18 + 4 + 27 + 6 + 20 + 6 + CGFloat(t.rows.count) * 16 + CGFloat(max(0, t.rows.count - 1)) * 2 + 8
    }

    /// The lists tile: header, 4, then `slots` 16 pt rows 4 apart, so the height is constant.
    private static func listsHeight(_ slots: Int) -> CGFloat { 8 + 18 + 4 + CGFloat(slots) * 16 + CGFloat(max(0, slots - 1)) * 4 + 8 }

    private static let footerLine: CGFloat = 15

    /// The blocks' frames: CPU · GPU, Memory · Disk (tiles in a row share the row's height), Power, the lists, the
    /// footer; and the box height in whole points (the window can't be fractional).
    private static func layout(_ c: PanelContent) -> (blocks: [(Block, CGRect)], height: CGFloat) {
        var blocks: [(Block, CGRect)] = []
        var y = padding
        let t = c.tiles
        for pair in [t[0..<2], t[2..<4]] {
            let h = pair.map(tileHeight).max() ?? 0
            for (i, tile) in pair.enumerated() {
                blocks.append((.tile(tile), CGRect(x: padding + CGFloat(i) * (half + gap), y: y, width: half, height: h)))
            }
            y += h + gap
        }
        blocks.append((.tile(t[4]), CGRect(x: padding, y: y, width: content, height: tileHeight(t[4]))))
        y += tileHeight(t[4])
        if let lists = c.lists {
            y += gap
            let h = listsHeight(lists.map(\.slots).max() ?? 0)
            blocks.append((.lists(lists), CGRect(x: padding, y: y, width: content, height: h)))
            y += h
        }
        if let footer = c.footer {
            y += gap
            blocks.append((.footer(footer), CGRect(x: padding, y: y, width: content, height: footerLine)))
            y += footerLine
        }
        return (blocks, (y + padding).rounded(.up))
    }

    /// The box height for `content` (the short-screen check, R-17).
    static func height(_ c: PanelContent) -> CGFloat { layout(c).height }

    /// Rebuilds the blocks for `p` and resizes to fit.
    func show(_ p: Panel) {
        panel = p
        let s = p.style
        box.subviews.forEach { $0.removeFromSuperview() }
        let (blocks, height) = Self.layout(p.content)
        for (block, frame) in blocks {
            let view = Drawn(frame: frame)
            switch block {
            case .tile(let t):
                view.paint = { Self.drawTile(t, s, in: $0.bounds) }
                view.setAccessibilityElement(true)
                view.setAccessibilityRole(.group)
                view.setAccessibilityLabel(t.label)
            case .lists(let lists):
                view.paint = { v in
                    Self.tileBackground(v.bounds, s)
                    s.sep.setFill() // the 1 pt divider between the columns, 8 pt gaps
                    CGRect(x: 8 + Self.listWidth + 8, y: 8, width: 1, height: v.bounds.height - 16).fill()
                }
                for (i, list) in lists.enumerated() { // one accessibility group per list
                    let column = Drawn(frame: CGRect(x: 8 + CGFloat(i) * (Self.listWidth + 17), y: 8, width: Self.listWidth,
                                                     height: frame.height - 16))
                    column.paint = { Self.drawList(list, s, width: $0.bounds.width) }
                    column.setAccessibilityElement(true)
                    column.setAccessibilityRole(.group)
                    column.setAccessibilityLabel(list.label)
                    view.addSubview(column)
                }
            case .footer(let text):
                view.paint = { _ in Self.text(text, Self.font(11), s.panelDim, x: 8, top: 0, line: Self.footerLine) }
                view.setAccessibilityElement(true)
                view.setAccessibilityRole(.staticText)
                view.setAccessibilityLabel(text)
            }
            box.addSubview(view)
        }
        setFrameSize(NSSize(width: Self.width, height: height))
        box.frame = bounds
        effect.frame = bounds
        effect.isHidden = s.reduceTransparency // DD-9: solid
        box.paint = { box in // the panel tint over the blur, radius 12, no border (deviation 9)
            s.panel.setFill()
            NSBezierPath(roundedRect: box.bounds, xRadius: 12, yRadius: 12).fill()
        }
        box.needsDisplay = true
        window?.invalidateShadow() // the native shadow follows the new shape
    }

    // MARK: Drawing

    /// The panel's text is the system font with tabular digits.
    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont { .monospacedDigitSystemFont(ofSize: size, weight: weight) }

    /// A run's font and colour: warning semibold amber, critical bold red, dim regular, otherwise `weight` in fg.
    private static func style(_ r: Run, _ s: Style, size: CGFloat, weight: NSFont.Weight) -> (NSFont, NSColor) {
        switch (r.level, r.dim) {
        case (.critical, _): (font(size, .bold), s.text(.critical))
        case (.warning, _): (font(size, .semibold), s.text(.warning))
        case (_, true): (font(size), s.panelDim)
        default: (font(size, weight), s.fg)
        }
    }

    /// Draws `string` in a CSS line box of `line` pt at `top` (glyphs centred as the browser does), tail-truncated
    /// to `width` if given, right-aligned at `x` when `right`. Returns the drawn width.
    @discardableResult
    static func text(_ string: String, _ font: NSFont, _ color: NSColor, x: CGFloat, top: CGFloat, line: CGFloat,
                     width: CGFloat? = nil, right: Bool = false) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let s = NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: para])
        let w = min(s.size().width, width ?? .greatestFiniteMagnitude)
        let baseline = top + (line - (font.ascender - font.descender)) / 2 + font.ascender
        let left = right ? x - w : x
        s.draw(with: CGRect(x: left, y: baseline - font.ascender, width: w + 0.5, height: font.ascender - font.descender + 2),
               options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return w
    }

    private static func tileBackground(_ rect: CGRect, _ s: Style) {
        s.tint.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
    }

    /// The header (`.th`, 18 pt): 14 pt glyph, 5 pt, the 13 pt semibold name; the 12 pt state word on the right
    /// (bolt 7 × 10 and 3 pt before it). Returns nothing; the line is 18 pt.
    private static func header(_ glyph: Column.Glyph, _ title: String, word: Run?, bolt: Bool, _ s: Style, x: CGFloat,
                               top: CGFloat, width: CGFloat) {
        Glance.glyph(glyph, in: CGRect(x: x, y: top + 2, width: 14, height: 14), s.fg)
        let titleWidth = text(title, font(13, .semibold), s.fg, x: x + 19, top: top, line: 18)
        guard let word else { return }
        let (f, color) = style(word, s, size: 12, weight: .medium)
        let left = x + 19 + titleWidth + 8
        let drawn = text(word.text, f, color, x: x + width, top: top, line: 18, width: max(0, x + width - left - (bolt ? 10 : 0)), right: true)
        if bolt { Glance.bolt(in: CGRect(x: x + width - drawn - 3 - 7, y: top + 4, width: 7, height: 10), color) }
    }

    /// One tile: header, primary value with its dim unit, the 20 pt graphic slot, key/value rows.
    private static func drawTile(_ t: Tile, _ s: Style, in rect: CGRect) {
        tileBackground(rect, s)
        let x: CGFloat = 8, inner = rect.width - 16
        var y: CGFloat = 8
        header(t.glyph, t.title, word: t.word, bolt: t.bolt, s, x: x, top: y, width: inner)
        y += 18 + 4
        // Primary: 20 pt semibold (bold red when critical), the unit 13 pt regular dim, 3 pt after, on one baseline.
        let (vf, vc) = style(t.value, s, size: 20, weight: .semibold)
        let w = text(t.value.text, vf, vc, x: x, top: y, line: 27)
        let unit = font(13)
        let baseline = y + (27 - (vf.ascender - vf.descender)) / 2 + vf.ascender
        NSAttributedString(string: t.unit, attributes: [.font: unit, .foregroundColor: s.panelDim])
            .draw(at: CGPoint(x: x + w + 3, y: baseline - unit.ascender))
        y += 27 + 6
        graphic(t.graphic, s, in: CGRect(x: x, y: y, width: inner, height: 20))
        y += 20 + 6
        for row in t.rows {
            var lx = x
            if let swatch = row.swatch { // 8 × 8, radius 2, at the segment's opacity
                s.fg.withAlphaComponent(swatch).setFill()
                NSBezierPath(roundedRect: CGRect(x: lx, y: y + 4, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
                lx += 13
            }
            text(row.label, font(12), s.panelDim, x: lx, top: y, line: 16)
            let (f, c) = style(row.value, s, size: 12, weight: .medium)
            text(row.value.text, f, c, x: x + inner, top: y, line: 16, right: true)
            y += 16 + 2
        }
    }

    /// The graphic slot: sparkline, gauge, capacity bar or power track; nothing for a missing value or on battery.
    private static func graphic(_ g: Tile.Graphic, _ s: Style, in r: CGRect) {
        let bar = CGRect(x: r.minX, y: r.midY - 3, width: r.width, height: 6) // 6 pt, radius 3, centred
        func rounded(_ rect: CGRect) -> NSBezierPath { NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3) }
        func levelFill(_ l: Level) -> NSColor { l == .normal ? s.fg.withAlphaComponent(0.7) : s.fill(l) }
        switch g {
        case .none: break
        case .spark(let samples): spark(samples, s.fg, in: r)
        case .gauge(let level): // three equal segments 3 pt apart: Normal lights 1, Warning 2, Critical 3
            let lit = level == .normal ? 1 : level == .warning ? 2 : 3
            let w = (r.width - 6) / 3
            for i in 0..<3 {
                (i < lit ? levelFill(level) : s.panelTrack).setFill()
                rounded(CGRect(x: r.minX + CGFloat(i) * (w + 3), y: bar.minY, width: w, height: 6)).fill()
            }
        case let .bar(fill, level):
            s.panelTrack.setFill()
            rounded(bar).fill()
            NSGraphicsContext.saveGraphicsState()
            rounded(bar).addClip()
            levelFill(level).setFill()
            CGRect(x: bar.minX, y: bar.minY, width: bar.width * fill, height: 6).fill()
            NSGraphicsContext.restoreGraphicsState()
        case let .track(system, battery): // system fg 85 %, then (charging) battery fg 38 % after a 2 pt gap
            s.panelTrack.setFill()
            rounded(bar).fill()
            NSGraphicsContext.saveGraphicsState()
            rounded(bar).addClip()
            s.fg.withAlphaComponent(0.85).setFill()
            CGRect(x: bar.minX, y: bar.minY, width: bar.width * system, height: 6).fill()
            if let battery, battery > 0 {
                s.fg.withAlphaComponent(0.38).setFill()
                CGRect(x: bar.minX + bar.width * system + 2, y: bar.minY, width: bar.width * battery, height: 6).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// The artifact's `spark()`: `History.capacity` slots, newest at the right edge (a short history grows leftward), fixed 0–100 %
    /// scale (y = 19 − v/100 × 18 of 20); each run between gaps gets a 14 % fill and a 1.3 pt round line.
    private static func spark(_ samples: [Int?], _ color: NSColor, in r: CGRect) {
        let offset = History.capacity - samples.count
        var runs: [[CGPoint]] = [[]]
        for (j, v) in samples.enumerated() {
            guard let v else { runs.append([]); continue }
            let i = CGFloat(offset + j)
            runs[runs.count - 1].append(CGPoint(x: r.minX + i / CGFloat(History.capacity - 1) * r.width,
                                                y: r.minY + 19 - CGFloat(max(0, min(100, v))) / 100 * 18))
        }
        for run in runs where run.count > 1 {
            let fill = NSBezierPath()
            fill.move(to: CGPoint(x: run[0].x, y: r.minY + 20))
            run.forEach { fill.line(to: $0) }
            fill.line(to: CGPoint(x: run[run.count - 1].x, y: r.minY + 20))
            fill.close()
            color.withAlphaComponent(0.14).setFill()
            fill.fill()
            let line = NSBezierPath()
            line.move(to: run[0])
            run.dropFirst().forEach { line.line(to: $0) }
            line.lineWidth = 1.3
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            color.setStroke()
            line.stroke()
        }
    }

    /// Each list column: (354 − 16 padding − 2 × 8 gaps − 1 divider) / 2.
    static let listWidth = (content - 16 - 17) / 2

    /// One list: header with the dim "5 of 8" note, then the rows (name tail-truncated, value medium on the right) or
    /// the dim message on the first line; empty slots stay blank.
    private static func drawList(_ l: ProcessList, _ s: Style, width: CGFloat) {
        let note = l.note.map { Run(text: $0, dim: true) }
        header(l.glyph, l.title, word: note, bolt: false, s, x: 0, top: 0, width: width)
        var y: CGFloat = 18 + 4
        if let message = l.message {
            text(message, font(12), s.panelDim, x: 0, top: y, line: 16, width: width)
            return
        }
        for row in l.rows {
            let valueFont = font(12, .medium)
            let w = text(row.value, valueFont, s.fg, x: width, top: y, line: 16, right: true)
            text(row.name, font(12), s.fg, x: 0, top: y, line: 16, width: max(0, width - w - 6))
            y += 16 + 4
        }
    }
}
