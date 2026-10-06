import Foundation

/// VT100 / XTerm 兼容的 ANSI 转义序列解析器 (状态机)
/// 支持: 光标移动/定位、擦除、滚动区域、插入删除行/字符、
///       SGR(16色/256色/真彩色/粗体/下划线/反显)、备用屏幕、OSC 标题
final class VTParser {

    private enum State {
        case ground
        case esc
        case csi
        case osc
        case dcs   // 吞掉 DCS..ST
    }

    let buf: TerminalBuffer

    private var state: State = .ground

    // CSI 参数收集
    private var params: [Int] = []
    private var curParam: Int = 0
    private var hasCurParam = false
    private var privateMark: UInt8 = 0  // '?' 或 '>'

    // OSC 收集
    private var oscBytes: [UInt8] = []
    private var oscSawEsc = false

    // UTF-8 解码
    private var u8need = 0
    private var u8val: UInt32 = 0

    init(buffer: TerminalBuffer) {
        self.buf = buffer
    }

    func reset() {
        state = .ground
        params.removeAll(keepingCapacity: true)
        oscBytes.removeAll(keepingCapacity: true)
        u8need = 0
    }

    // MARK: - 输入

    func feed(_ data: Data) {
        for byte in data {
            process(byte)
        }
    }

    @inline(__always)
    private func process(_ b: UInt8) {
        switch state {
        case .ground: processGround(b)
        case .esc: processEsc(b)
        case .csi: processCSI(b)
        case .osc: processOSC(b)
        case .dcs: processDCS(b)
        }
    }

    // MARK: - Ground: 可打印字符 + C0 控制符 + UTF-8

    @inline(__always)
    private func processGround(_ b: UInt8) {
        // UTF-8 多字节续字节
        if u8need > 0 {
            if b & 0xC0 == 0x80 {
                u8val = (u8val << 6) | UInt32(b & 0x3F)
                u8need -= 1
                if u8need == 0 { buf.put(u8val) }
                return
            }
            // 非法序列: 丢弃已收的字节, 当前字节按新字符重新处理 (不直接 return)
            u8need = 0
        }
        if b >= 0x80 {
            if b & 0xE0 == 0xC0 { u8val = UInt32(b & 0x1F); u8need = 1 }
            else if b & 0xF0 == 0xE0 { u8val = UInt32(b & 0x0F); u8need = 2 }
            else if b & 0xF8 == 0xF0 { u8val = UInt32(b & 0x07); u8need = 3 }
            return
        }
        switch b {
        case 0x07: break                          // BEL 忽略
        case 0x08: buf.backspace()                // BS
        case 0x09: buf.tab()                      // HT
        case 0x0A, 0x0B, 0x0C: buf.lineFeed()     // LF/VT/FF
        case 0x0D: buf.carriageReturn()           // CR
        case 0x1B: state = .esc                   // ESC
        case 0x20...0x7E: buf.put(UInt32(b))      // 可打印 ASCII
        case 0x7F: break                          // DEL 忽略
        default: break
        }
    }

    // MARK: - ESC

    private func processEsc(_ b: UInt8) {
        switch b {
        case 0x1B: break                          // ESC ESC
        case 0x5B:                                // ESC [
            state = .csi
            params.removeAll(keepingCapacity: true)
            curParam = 0; hasCurParam = false; privateMark = 0
        case 0x5D:                                // ESC ] -> OSC
            state = .osc
            oscBytes.removeAll(keepingCapacity: true)
            oscSawEsc = false
        case 0x50, 0x58, 0x5E, 0x5F:              // DCS/SOS/PM/APC: 吞到 ST
            state = .dcs
        case 0x4D: buf.reverseIndex(); state = .ground   // ESC M
        case 0x44: buf.lineFeed(); state = .ground       // ESC D
        case 0x45: buf.carriageReturn(); buf.lineFeed(); state = .ground // ESC E
        case 0x37: buf.saveCursor(); state = .ground     // ESC 7
        case 0x38: buf.restoreCursor(); state = .ground  // ESC 8
        case 0x63: resetTerminal(); state = .ground       // ESC c
        case 0x20...0x2F: break                   // 中间字节, 留在 esc
        case 0x30...0x7E: state = .ground          // 其他单字符序列忽略
        default: state = .ground
        }
    }

    private func resetTerminal() {
        buf.clearAll()
        buf.resetAttrs()
        buf.wrapMode = true
        buf.originMode = false
        buf.insertMode = false
        buf.cursorVisible = true
        buf.setScrollRegion(top: 0, bottom: buf.rows - 1)
        if buf.usingAlt { buf.useAltScreen(false) }
    }

    // MARK: - CSI

    private func pushParam() {
        params.append(hasCurParam ? curParam : -1)  // -1 = 缺省
        curParam = 0; hasCurParam = false
    }

    private func processCSI(_ b: UInt8) {
        switch b {
        case 0x30...0x39:
            curParam = curParam * 10 + Int(b - 0x30)
            hasCurParam = true
        case 0x3B:
            pushParam()
        case 0x3F, 0x3E:                          // '?' '>'
            privateMark = b
        case 0x20...0x2F: break                   // 中间字节忽略
        case 0x40...0x7E:
            pushParam()
            dispatchCSI(final: b)
            state = .ground
        default:
            state = .ground
        }
    }

    /// 取第 i 个参数, 缺省/-1 时返回 d
    private func P(_ i: Int, _ d: Int) -> Int {
        if i < params.count {
            let v = params[i]
            return v < 0 ? d : v
        }
        return d
    }

    private func dispatchCSI(final: UInt8) {
        let b = buf
        // 私有模式 ?...h / ?...l
        if privateMark == 0x3F && (final == 0x68 || final == 0x6C) {
            let on = (final == 0x68)
            for p in params {
                switch p {
                case 25: b.cursorVisible = on
                case 1049:
                    b.saveCursor()
                    b.useAltScreen(on)
                    if on { b.clearAll() } else { b.restoreCursor() }
                case 1047:
                    b.useAltScreen(on)
                    if on { b.clearAll() }
                case 1048:
                    if on { b.saveCursor() } else { b.restoreCursor() }
                default: break
                }
            }
            return
        }

        switch final {
        case 0x41: b.moveCursor(dx: 0, dy: -P(0, 1))          // CUU
        case 0x42: b.moveCursor(dx: 0, dy: P(0, 1))           // CUD
        case 0x43: b.moveCursor(dx: P(0, 1), dy: 0)           // CUF
        case 0x44: b.moveCursor(dx: -P(0, 1), dy: 0)          // CUB
        case 0x45: b.moveCursor(dx: -b.cursorX, dy: P(0, 1))  // CNL
        case 0x46: b.moveCursor(dx: -b.cursorX, dy: -P(0, 1)) // CPL
        case 0x47: b.setCursor(row: b.cursorY, col: P(0, 1) - 1) // CHA
        case 0x48, 0x66:                                     // CUP / HVP
            b.setCursor(row: P(0, 1) - 1, col: P(1, 1) - 1)
        case 0x64:                                           // VPA
            b.setCursor(row: P(0, 1) - 1, col: b.cursorX)
        case 0x4A: b.eraseDisplay(P(0, 0))                   // ED
        case 0x4B: b.eraseLine(P(0, 0))                      // EL
        case 0x53: b.scrollUp(P(0, 1))                       // SU
        case 0x54: b.scrollDown(P(0, 1))                     // SD
        case 0x4C: b.insertLines(P(0, 1))                    // IL
        case 0x4D: b.deleteLines(P(0, 1))                    // DL
        case 0x50: b.deleteChars(P(0, 1))                    // DCH
        case 0x40: b.insertChars(P(0, 1))                    // ICH
        case 0x58: b.eraseChars(P(0, 1))                     // ECH
        case 0x6D: applySGR()                                // SGR
        case 0x72:                                           // DECSTBM
            b.setScrollRegion(top: P(0, 1) - 1, bottom: P(1, b.rows) - 1)
        case 0x73: b.saveCursor()                            // SC
        case 0x75: b.restoreCursor()                         // RC
        case 0x68, 0x6C: break                               // 非私有 SM/RM 忽略
        case 0x6E, 0x63, 0x71: break                         // DSR/DA/光标样式 忽略
        default: break
        }
    }

    // MARK: - SGR

    private func applySGR() {
        let b = buf
        var i = 0
        if params.isEmpty { b.resetAttrs(); return }
        while i < params.count {
            let c = params[i] < 0 ? 0 : params[i]
            switch c {
            case 0: b.resetAttrs()
            case 1: b.curFlags |= CellFlags.bold
            case 4: b.curFlags |= CellFlags.underline
            case 7: b.curFlags |= CellFlags.reverse
            case 22: b.curFlags &= ~CellFlags.bold
            case 24: b.curFlags &= ~CellFlags.underline
            case 27: b.curFlags &= ~CellFlags.reverse
            case 30...37: b.curFG = termPalette16[c - 30]
            case 39: b.curFG = b.defaultFG
            case 40...47: b.curBG = termPalette16[c - 40]
            case 49: b.curBG = b.defaultBG
            case 90...97: b.curFG = termPalette16[c - 90 + 8]
            case 100...107: b.curBG = termPalette16[c - 100 + 8]
            case 38, 48:
                let isFG = (c == 38)
                let nxt = (i + 1 < params.count) ? params[i + 1] : -1
                if nxt == 5, i + 2 < params.count, params[i + 2] >= 0 {
                    let col = termColor256(min(params[i + 2], 255))
                    if isFG { b.curFG = col } else { b.curBG = col }
                    i += 2
                } else if nxt == 2, i + 4 < params.count {
                    let r = UInt8(min(max(params[i + 2], 0), 255))
                    let g = UInt8(min(max(params[i + 3], 0), 255))
                    let bl = UInt8(min(max(params[i + 4], 0), 255))
                    let col = termRGBA(r, g, bl)
                    if isFG { b.curFG = col } else { b.curBG = col }
                    i += 4
                }
            default: break
            }
            i += 1
        }
    }

    // MARK: - OSC (标题等)

    private func processOSC(_ b: UInt8) {
        if oscSawEsc {
            oscSawEsc = false
            if b == 0x5C { finishOSC() }   // ESC \
            else { oscBytes.append(0x1B); oscBytes.append(b) }
            return
        }
        if b == 0x1B { oscSawEsc = true; return }
        if b == 0x07 { finishOSC(); return }  // BEL
        oscBytes.append(b)
    }

    private func finishOSC() {
        state = .ground
        guard let s = String(bytes: oscBytes, encoding: .utf8) else { return }
        // 0;title 或 2;title
        if s.hasPrefix("0;") || s.hasPrefix("2;") {
            buf.title = String(s.dropFirst(2))
        }
    }

    // MARK: - DCS: 吞到 ST

    private var dcsSawEsc = false

    private func processDCS(_ b: UInt8) {
        if dcsSawEsc {
            dcsSawEsc = false
            if b == 0x5C { state = .ground }
            return
        }
        if b == 0x1B { dcsSawEsc = true }
    }
}
