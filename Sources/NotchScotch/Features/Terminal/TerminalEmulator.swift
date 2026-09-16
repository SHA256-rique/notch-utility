import Foundation
import SwiftUI

/// A deliberately small VT100/xterm screen model and parser.
///
/// ## Scope, stated honestly
/// This is not a complete terminal emulator and does not try to be. It covers
/// what an interactive shell session, `git`, `npm`, `claude` and similar tools
/// actually emit: SGR colour/attributes, cursor movement, erase, scroll regions,
/// alternate screen buffer, and line wrap. It does **not** implement sixel
/// graphics, mouse reporting, double-width lines, or the full DEC private mode
/// set. Programs that need those (a full `vim` session with mouse support) will
/// render imperfectly -- which is the accepted trade for not taking a
/// dependency, and for a terminal that lives in a 680pt notch panel.
///
/// ## Why hand-rolled instead of SwiftTerm
/// SwiftTerm is good and would have worked. It was rejected because: it is a
/// package dependency in an app that has deliberately zero (see Package.swift);
/// it carries a full xterm feature set whose per-session allocations are far
/// larger than this use case needs; and its NSView-based renderer would have to
/// be bridged into SwiftUI anyway. ~600 lines under our own control, that tear
/// down cleanly when a tab closes, fit this app's constraints better than a
/// well-engineered general-purpose one.
///
/// ## Memory
/// Scrollback is hard-capped. A terminal that keeps unlimited history is a
/// memory leak with a user interface -- `cat`ing a large file would grow the
/// process without bound. 2,000 lines is generous for a panel this size.
final class TerminalEmulator {

    struct Cell: Equatable {
        var character: Character = " "
        var foreground: UInt8 = 7      // ANSI index; 256 means "default"
        var background: UInt8 = 0
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false

        static let blank = Cell()
    }

    struct Line: Equatable {
        var cells: [Cell]
        /// Set when the line was wrapped rather than newline-terminated. Kept so
        /// a future reflow-on-resize can rejoin them.
        var wrapped = false
    }

    // MARK: - Screen state

    private(set) var lines: [Line] = []
    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var cursorVisible = true

    private(set) var columns: Int
    private(set) var rows: Int

    static let maxScrollback = 2000

    /// Alternate screen buffer (what full-screen apps switch into). Saved
    /// separately so exiting `less` restores what was underneath.
    private var savedPrimary: [Line]?
    private var savedCursor: (row: Int, column: Int)?
    private(set) var isAlternateScreen = false

    // Scroll region (DECSTBM), inclusive, in screen-relative coordinates.
    private var scrollTop = 0
    private var scrollBottom: Int

    private var current = Cell()

    // Parser state
    private enum ParseState { case ground, escape, csi, osc, charset }
    private var state: ParseState = .ground
    private var parameterBuffer = ""
    private var intermediateBuffer = ""
    private var oscBuffer = ""
    /// UTF-8 continuation accumulator: a multi-byte codepoint can be split
    /// across two reads from the pty, and decoding each chunk independently
    /// would corrupt every emoji and accented character at a buffer boundary.
    private var utf8Pending: [UInt8] = []

    /// Bumped on every mutation so SwiftUI can invalidate cheaply without
    /// diffing the whole grid.
    private(set) var generation: Int = 0

    init(columns: Int = 100, rows: Int = 28) {
        self.columns = max(20, columns)
        self.rows = max(4, rows)
        self.scrollBottom = self.rows - 1
        self.lines = (0..<self.rows).map { _ in Line(cells: Array(repeating: .blank, count: self.columns)) }
    }

    // MARK: - Public API

    func feed(_ data: Data) {
        var bytes = utf8Pending + Array(data)
        utf8Pending = []

        var index = 0
        while index < bytes.count {
            let byte = bytes[index]

            // ASCII / control fast path.
            if byte < 0x80 {
                process(scalar: Character(UnicodeScalar(byte)), raw: byte)
                index += 1
                continue
            }

            // Multi-byte UTF-8: work out the sequence length and hold back an
            // incomplete tail for the next feed().
            let length: Int
            switch byte {
            case 0xC0...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF7: length = 4
            default: index += 1; continue          // stray continuation byte
            }
            guard index + length <= bytes.count else {
                utf8Pending = Array(bytes[index...])
                break
            }
            let slice = Array(bytes[index..<(index + length)])
            if let text = String(bytes: slice, encoding: .utf8), let character = text.first {
                process(scalar: character, raw: 0)
            }
            index += length
        }
        bytes = []
        generation &+= 1
    }

    func resize(columns newColumns: Int, rows newRows: Int) {
        let c = max(20, newColumns), r = max(4, newRows)
        guard c != columns || r != rows else { return }
        columns = c
        rows = r
        scrollTop = 0
        scrollBottom = r - 1
        for index in lines.indices {
            if lines[index].cells.count < c {
                lines[index].cells.append(contentsOf:
                    Array(repeating: .blank, count: c - lines[index].cells.count))
            } else if lines[index].cells.count > c {
                lines[index].cells.removeLast(lines[index].cells.count - c)
            }
        }
        while lines.count < r {
            lines.append(Line(cells: Array(repeating: .blank, count: c)))
        }

        // Shrinking needs the opposite, and its absence was a real bug.
        //
        // `visibleLines` is the *last* `rows` lines of the buffer. Growing the
        // array on resize but never shrinking it meant that after a screen got
        // shorter -- splitting one terminal into four, say -- `lines.count`
        // stayed at the old height while `rows` dropped, so the window slid
        // down the buffer and the top of the output scrolled off. A shell that
        // had printed one prompt showed a completely blank pane.
        //
        // Only *blank trailing* lines are dropped, and never the cursor's own.
        // Genuine scrollback is lines with content on them, and shrinking the
        // window must not discard it.
        while lines.count > r,
              cursorRow < lines.count - 1,
              lines[lines.count - 1].cells.allSatisfy({ $0.character == " " }) {
            lines.removeLast()
        }

        cursorRow = min(cursorRow, lines.count - 1)
        cursorColumn = min(cursorColumn, c - 1)
        clampScrollOffset()
        generation &+= 1
    }

    // MARK: - Viewport

    /// How many lines the viewport is scrolled back from the live bottom.
    ///
    /// Held here rather than in the view because it has to be clamped against
    /// the buffer, and the buffer is what trims itself when scrollback overflows.
    /// A view-owned offset would silently drift every time a line rolled off the
    /// top during a long build.
    private(set) var scrollOffset = 0

    var maxScrollOffset: Int { max(0, lines.count - rows) }
    var isScrolledBack: Bool { scrollOffset > 0 }

    /// Index into `lines` of the first row currently rendered.
    var firstVisibleLineIndex: Int {
        max(0, lines.count - rows - scrollOffset)
    }

    /// The window of lines that should be rendered. Normally the last `rows` of
    /// the buffer, where the cursor lives; further back when scrolled.
    var visibleLines: ArraySlice<Line> {
        let start = firstVisibleLineIndex
        let end = min(lines.count, start + rows)
        return lines[start..<end]
    }

    /// The cursor's row within the rendered window, or a negative/overflowing
    /// value when it is scrolled out of sight -- which the renderer reads as
    /// "do not draw a cursor".
    var visibleCursorRow: Int {
        cursorRow - firstVisibleLineIndex
    }

    /// Scrolls the viewport. Positive is back into history.
    ///
    /// The alternate screen has no scrollback by definition -- `less` and `vim`
    /// draw their own scrolling -- so this is a no-op there rather than showing
    /// the primary buffer bleeding through underneath.
    func scroll(by delta: Int) {
        guard !isAlternateScreen else { return }
        let next = max(0, min(maxScrollOffset, scrollOffset + delta))
        guard next != scrollOffset else { return }
        scrollOffset = next
        generation &+= 1
    }

    func scrollToBottom() {
        guard scrollOffset != 0 else { return }
        scrollOffset = 0
        generation &+= 1
    }

    /// Absolute buffer coordinates, used by selection so that a selection made
    /// before a build scrolled the screen still covers the same characters.
    struct Position: Equatable, Comparable {
        var line: Int
        var column: Int
        static func < (a: Position, b: Position) -> Bool {
            a.line == b.line ? a.column < b.column : a.line < b.line
        }
    }

    /// Text between two absolute positions, inclusive of `from`, exclusive of
    /// `to`. Trailing blanks on each line are dropped, because a terminal pads
    /// every row out to the full width and pasting eighty spaces after each line
    /// is never what anyone wanted.
    func text(from: Position, to: Position) -> String {
        let (start, end) = from <= to ? (from, to) : (to, from)
        guard start.line < lines.count else { return "" }
        var output: [String] = []
        for index in start.line...min(end.line, lines.count - 1) {
            let cells = lines[index].cells
            let lower = index == start.line ? min(start.column, cells.count) : 0
            let upper = index == end.line ? min(end.column + 1, cells.count) : cells.count
            guard lower < upper else { output.append(""); continue }
            let text = String(cells[lower..<upper].map(\.character))
            output.append(String(text.reversed().drop { $0 == " " }.reversed()))
        }
        return output.joined(separator: "\n")
    }

    func reset() {
        lines = (0..<rows).map { _ in Line(cells: Array(repeating: .blank, count: columns)) }
        cursorRow = 0; cursorColumn = 0
        current = Cell()
        state = .ground
        isAlternateScreen = false
        savedPrimary = nil
        scrollOffset = 0
        generation &+= 1
    }

    // MARK: - Parser

    private func process(scalar: Character, raw: UInt8) {
        switch state {
        case .ground:  ground(scalar, raw)
        case .escape:  escape(scalar)
        case .csi:     csi(scalar)
        case .osc:     osc(scalar)
        case .charset: state = .ground     // consume and ignore the designator
        }
    }

    private func ground(_ character: Character, _ raw: UInt8) {
        switch raw {
        case 0x1B: state = .escape; parameterBuffer = ""; intermediateBuffer = ""
        case 0x07: return                                  // BEL — deliberately silent
        case 0x08: cursorColumn = max(0, cursorColumn - 1)  // BS
        case 0x09:                                         // HT
            cursorColumn = min(columns - 1, ((cursorColumn / 8) + 1) * 8)
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: cursorColumn = 0
        default:
            guard raw >= 0x20 || raw == 0 else { return }
            put(character)
        }
    }

    private func escape(_ character: Character) {
        switch character {
        case "[": state = .csi; parameterBuffer = ""; intermediateBuffer = ""
        case "]": state = .osc; oscBuffer = ""
        case "(", ")", "*", "+": state = .charset
        case "M":                                           // RI — reverse index
            if cursorRow == scrollTopAbsolute { scrollDown() } else { cursorRow = max(0, cursorRow - 1) }
            state = .ground
        case "D": lineFeed(); state = .ground               // IND
        case "E": lineFeed(); cursorColumn = 0; state = .ground  // NEL
        case "7": savedCursor = (cursorRow, cursorColumn); state = .ground
        case "8":
            if let saved = savedCursor { cursorRow = saved.row; cursorColumn = saved.column }
            state = .ground
        case "c": reset(); state = .ground                  // RIS
        default: state = .ground
        }
    }

    private func csi(_ character: Character) {
        if character.isNumber || character == ";" || character == "?" || character == ">" || character == "!" {
            parameterBuffer.append(character)
            return
        }
        if character == " " || character == "$" || character == "\"" {
            intermediateBuffer.append(character)
            return
        }
        defer { state = .ground; parameterBuffer = ""; intermediateBuffer = "" }

        let isPrivate = parameterBuffer.hasPrefix("?")
        let raw = isPrivate ? String(parameterBuffer.dropFirst()) : parameterBuffer
        let parameters = raw.split(separator: ";", omittingEmptySubsequences: false)
            .map { Int($0) ?? 0 }
        func parameter(_ index: Int, _ fallback: Int = 1) -> Int {
            guard index < parameters.count else { return fallback }
            return parameters[index] == 0 ? fallback : parameters[index]
        }

        switch character {
        case "A": cursorRow = max(scrollTopAbsolute, cursorRow - parameter(0))
        case "B": cursorRow = min(lines.count - 1, cursorRow + parameter(0))
        case "C": cursorColumn = min(columns - 1, cursorColumn + parameter(0))
        case "D": cursorColumn = max(0, cursorColumn - parameter(0))
        case "E": cursorRow = min(lines.count - 1, cursorRow + parameter(0)); cursorColumn = 0
        case "F": cursorRow = max(0, cursorRow - parameter(0)); cursorColumn = 0
        case "G", "`": cursorColumn = min(columns - 1, parameter(0) - 1)
        case "d": cursorRow = screenTop + min(rows - 1, parameter(0) - 1)
        case "H", "f":
            cursorRow = screenTop + min(rows - 1, parameter(0) - 1)
            cursorColumn = min(columns - 1, parameter(1) - 1)
        case "J": eraseInDisplay(parameters.first ?? 0)
        case "K": eraseInLine(parameters.first ?? 0)
        case "L": insertLines(parameter(0))
        case "M": deleteLines(parameter(0))
        case "P": deleteCharacters(parameter(0))
        case "@": insertCharacters(parameter(0))
        case "X": eraseCharacters(parameter(0))
        case "S": for _ in 0..<parameter(0) { scrollUp() }
        case "T": for _ in 0..<parameter(0) { scrollDown() }
        case "r":
            scrollTop = max(0, parameter(0) - 1)
            scrollBottom = min(rows - 1, parameters.count > 1 ? parameter(1, rows) - 1 : rows - 1)
            cursorRow = screenTop + scrollTop
            cursorColumn = 0
        case "m": applySGR(parameters.isEmpty ? [0] : parameters)
        case "s": savedCursor = (cursorRow, cursorColumn)
        case "u": if let saved = savedCursor { cursorRow = saved.row; cursorColumn = saved.column }
        case "h": setMode(parameters, enabled: true, isPrivate: isPrivate)
        case "l": setMode(parameters, enabled: false, isPrivate: isPrivate)
        default: break
        }
    }

    private func osc(_ character: Character) {
        // OSC runs until BEL or ST (ESC \). We only care about terminating it
        // cleanly -- window-title sequences have nowhere to go in this UI.
        if character == "\u{07}" { state = .ground; oscBuffer = ""; return }
        if character == "\\" && oscBuffer.hasSuffix("\u{1B}") { state = .ground; oscBuffer = ""; return }
        oscBuffer.append(character)
        if oscBuffer.count > 512 { state = .ground; oscBuffer = "" }   // runaway guard
    }

    // MARK: - Modes

    private func setMode(_ parameters: [Int], enabled: Bool, isPrivate: Bool) {
        guard isPrivate else { return }
        for parameter in parameters {
            switch parameter {
            case 25: cursorVisible = enabled
            case 1049, 47, 1047:
                enabled ? enterAlternateScreen() : exitAlternateScreen()
            default: break
            }
        }
    }

    private func enterAlternateScreen() {
        guard !isAlternateScreen else { return }
        savedPrimary = lines
        savedCursor = (cursorRow, cursorColumn)
        lines = (0..<rows).map { _ in Line(cells: Array(repeating: .blank, count: columns)) }
        cursorRow = 0; cursorColumn = 0
        isAlternateScreen = true
    }

    private func exitAlternateScreen() {
        guard isAlternateScreen, let saved = savedPrimary else { return }
        lines = saved
        if let cursor = savedCursor { cursorRow = cursor.row; cursorColumn = cursor.column }
        savedPrimary = nil
        isAlternateScreen = false
    }

    // MARK: - SGR

    private func applySGR(_ parameters: [Int]) {
        var index = 0
        while index < parameters.count {
            let parameter = parameters[index]
            switch parameter {
            case 0: current = Cell()
            case 1: current.bold = true
            case 2: current.dim = true
            case 3: current.italic = true
            case 4: current.underline = true
            case 7: current.inverse = true
            case 22: current.bold = false; current.dim = false
            case 23: current.italic = false
            case 24: current.underline = false
            case 27: current.inverse = false
            case 30...37: current.foreground = UInt8(parameter - 30)
            case 39: current.foreground = 7
            case 40...47: current.background = UInt8(parameter - 40)
            case 49: current.background = 0
            case 90...97: current.foreground = UInt8(parameter - 90 + 8)
            case 100...107: current.background = UInt8(parameter - 100 + 8)
            case 38, 48:
                // Extended colour. `5;n` is the 256-colour palette, `2;r;g;b` is
                // truecolour -- which we approximate down to the 256 cube rather
                // than widening every Cell by three bytes for a panel this size.
                guard index + 1 < parameters.count else { index = parameters.count; break }
                let mode = parameters[index + 1]
                if mode == 5, index + 2 < parameters.count {
                    let value = UInt8(clamping: parameters[index + 2])
                    if parameter == 38 { current.foreground = value } else { current.background = value }
                    index += 2
                } else if mode == 2, index + 4 < parameters.count {
                    let value = Self.nearest256(r: parameters[index + 2],
                                                g: parameters[index + 3],
                                                b: parameters[index + 4])
                    if parameter == 38 { current.foreground = value } else { current.background = value }
                    index += 4
                }
            default: break
            }
            index += 1
        }
    }

    private static func nearest256(r: Int, g: Int, b: Int) -> UInt8 {
        // The xterm 6x6x6 colour cube occupies indices 16-231.
        func level(_ v: Int) -> Int { max(0, min(5, (v - 35) / 40)) }
        return UInt8(16 + 36 * level(r) + 6 * level(g) + level(b))
    }

    // MARK: - Screen operations

    private var screenTop: Int { max(0, lines.count - rows) }
    private var scrollTopAbsolute: Int { screenTop + scrollTop }
    private var scrollBottomAbsolute: Int { min(lines.count - 1, screenTop + scrollBottom) }

    private func put(_ character: Character) {
        if cursorColumn >= columns {
            if cursorRow < lines.count { lines[cursorRow].wrapped = true }
            cursorColumn = 0
            lineFeed()
        }
        ensureRow(cursorRow)
        var cell = current
        cell.character = character
        lines[cursorRow].cells[cursorColumn] = cell
        cursorColumn += 1
    }

    private func ensureRow(_ row: Int) {
        while lines.count <= row {
            lines.append(Line(cells: Array(repeating: .blank, count: columns)))
        }
    }

    private func lineFeed() {
        if cursorRow >= scrollBottomAbsolute {
            scrollUp()
        } else {
            cursorRow += 1
            ensureRow(cursorRow)
        }
    }

    private func scrollUp() {
        if scrollTop == 0 && scrollBottom == rows - 1 {
            // Whole-screen scroll: append a line and let it become scrollback.
            lines.append(Line(cells: Array(repeating: .blank, count: columns)))
            trimScrollback()
            cursorRow = lines.count - 1
        } else {
            // Region scroll: rotate within the region only.
            let top = scrollTopAbsolute, bottom = scrollBottomAbsolute
            guard top < bottom, bottom < lines.count else { return }
            lines.remove(at: top)
            lines.insert(Line(cells: Array(repeating: .blank, count: columns)), at: bottom)
        }
    }

    private func scrollDown() {
        let top = scrollTopAbsolute, bottom = scrollBottomAbsolute
        guard top <= bottom, bottom < lines.count else { return }
        lines.remove(at: bottom)
        lines.insert(Line(cells: Array(repeating: .blank, count: columns)), at: top)
    }

    /// Keeps the viewport inside the buffer after anything that can change
    /// `lines.count` -- a resize, or scrollback rolling off the top during a
    /// long build. Without it a scrolled-back viewport silently drifts.
    private func clampScrollOffset() {
        scrollOffset = max(0, min(maxScrollOffset, scrollOffset))
    }

    /// The hard memory cap. Without this, `cat bigfile` is an OOM.
    private func trimScrollback() {
        guard !isAlternateScreen else {
            // The alternate screen has no scrollback by definition.
            if lines.count > rows { lines.removeFirst(lines.count - rows) }
            return
        }
        let limit = Self.maxScrollback + rows
        if lines.count > limit {
            let excess = lines.count - limit
            lines.removeFirst(excess)
            cursorRow = max(0, cursorRow - excess)
            // The lines the viewport was anchored to have gone; shrink the
            // offset by the same amount so the user keeps looking at the same
            // text rather than being scrolled further back.
            scrollOffset = max(0, scrollOffset - excess)
        }
        clampScrollOffset()
    }

    private func eraseInDisplay(_ mode: Int) {
        ensureRow(cursorRow)
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursorRow + 1)..<max(cursorRow + 1, lines.count) {
                lines[row].cells = Array(repeating: blankWithBackground(), count: columns)
            }
        case 1:
            eraseInLine(1)
            for row in screenTop..<cursorRow where row < lines.count {
                lines[row].cells = Array(repeating: blankWithBackground(), count: columns)
            }
        default:
            // Mode 2/3: clear the visible screen. Keeping scrollback intact on 2
            // matches what xterm does and what users expect from `clear`.
            for row in screenTop..<lines.count {
                lines[row].cells = Array(repeating: blankWithBackground(), count: columns)
            }
            cursorRow = screenTop
            cursorColumn = 0
        }
    }

    private func eraseInLine(_ mode: Int) {
        ensureRow(cursorRow)
        switch mode {
        case 0: for column in cursorColumn..<columns { lines[cursorRow].cells[column] = blankWithBackground() }
        case 1: for column in 0...min(cursorColumn, columns - 1) { lines[cursorRow].cells[column] = blankWithBackground() }
        default: lines[cursorRow].cells = Array(repeating: blankWithBackground(), count: columns)
        }
    }

    private func eraseCharacters(_ count: Int) {
        ensureRow(cursorRow)
        for column in cursorColumn..<min(columns, cursorColumn + count) {
            lines[cursorRow].cells[column] = blankWithBackground()
        }
    }

    /// ICH: shift the rest of the line right, dropping whatever falls off the
    /// end. The line length must stay exactly `columns` afterwards.
    private func insertCharacters(_ count: Int) {
        ensureRow(cursorRow)
        let at = min(cursorColumn, columns - 1)
        let shift = min(count, columns - at)
        guard shift > 0 else { return }
        lines[cursorRow].cells.insert(contentsOf: Array(repeating: blankWithBackground(), count: shift), at: at)
        lines[cursorRow].cells.removeLast(shift)
    }

    private func deleteCharacters(_ count: Int) {
        ensureRow(cursorRow)
        for _ in 0..<count where cursorColumn < lines[cursorRow].cells.count {
            lines[cursorRow].cells.remove(at: cursorColumn)
            lines[cursorRow].cells.append(blankWithBackground())
        }
    }

    private func insertLines(_ count: Int) {
        let bottom = scrollBottomAbsolute
        for _ in 0..<count {
            guard cursorRow <= bottom, bottom < lines.count else { break }
            lines.insert(Line(cells: Array(repeating: blankWithBackground(), count: columns)), at: cursorRow)
            lines.remove(at: bottom + 1 < lines.count ? bottom + 1 : lines.count - 1)
        }
    }

    private func deleteLines(_ count: Int) {
        let bottom = scrollBottomAbsolute
        for _ in 0..<count {
            guard cursorRow < lines.count, cursorRow <= bottom else { break }
            lines.remove(at: cursorRow)
            lines.insert(Line(cells: Array(repeating: blankWithBackground(), count: columns)),
                         at: min(bottom, lines.count))
        }
    }

    /// Erase operations must paint the *current* background colour, not black,
    /// or clearing inside a coloured region leaves holes.
    private func blankWithBackground() -> Cell {
        var cell = Cell.blank
        cell.background = current.background
        return cell
    }

    /// Plain-text dump of the buffer, used by the stdout-watching approval
    /// detector and by "copy all".
    func plainText(lastLines: Int? = nil) -> String {
        let slice = lastLines.map { Array(lines.suffix($0)) } ?? lines
        return slice.map { line in
            String(line.cells.map(\.character))
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n")
    }
}

/// ANSI palette. Matches the xterm defaults closely enough that colour-coded CLI
/// output (git status, npm warnings, test runners) looks right.
enum ANSIPalette {
    static func color(_ index: UInt8, bold: Bool) -> Color {
        let effective = (bold && index < 8) ? index + 8 : index
        switch effective {
        case 0:  return Color(red: 0.16, green: 0.16, blue: 0.18)
        case 1:  return Color(red: 0.88, green: 0.30, blue: 0.32)
        case 2:  return Color(red: 0.36, green: 0.80, blue: 0.42)
        case 3:  return Color(red: 0.90, green: 0.73, blue: 0.30)
        case 4:  return Color(red: 0.36, green: 0.60, blue: 0.94)
        case 5:  return Color(red: 0.76, green: 0.46, blue: 0.92)
        case 6:  return Color(red: 0.30, green: 0.78, blue: 0.80)
        case 7:  return Color(red: 0.84, green: 0.85, blue: 0.87)
        case 8:  return Color(red: 0.42, green: 0.43, blue: 0.47)
        case 9:  return Color(red: 1.00, green: 0.42, blue: 0.44)
        case 10: return Color(red: 0.48, green: 0.92, blue: 0.54)
        case 11: return Color(red: 1.00, green: 0.85, blue: 0.42)
        case 12: return Color(red: 0.48, green: 0.72, blue: 1.00)
        case 13: return Color(red: 0.88, green: 0.58, blue: 1.00)
        case 14: return Color(red: 0.42, green: 0.90, blue: 0.92)
        case 15: return Color.white
        case 16...231:
            // The 6x6x6 cube.
            let value = Int(effective) - 16
            let steps: [Double] = [0, 0.373, 0.529, 0.686, 0.843, 1.0]
            return Color(red: steps[value / 36], green: steps[(value % 36) / 6], blue: steps[value % 6])
        default:
            // The 24-step greyscale ramp.
            let level = Double(Int(effective) - 232) / 23.0
            return Color(white: 0.03 + level * 0.92)
        }
    }
}
