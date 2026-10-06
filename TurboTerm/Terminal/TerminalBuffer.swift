import Foundation

// MARK: - 颜色: 打包为 0xRRGGBBAA, 方便一次拷贝进顶点

typealias TermColor = UInt32

@inline(__always)
func termRGBA(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> TermColor {
    return (UInt32(r) << 24) | (UInt32(g) << 16) | (UInt32(b) << 8) | UInt32(a)
}

@inline(__always)
func termColor256(_ n: Int) -> TermColor {
    if n < 8 { return termPalette16[n] }
    if n < 16 { return termPalette16[n] }
    if n < 232 {
        let v = n - 16
        let r = v / 36, g = (v / 6) % 6, b = v % 6
        func comp(_ c: Int) -> UInt8 { return c == 0 ? 0 : UInt8(55 + 40 * c) }
        return termRGBA(comp(r), comp(g), comp(b))
    }
    let gray = UInt8(8 + 10 * (n - 232))
    return termRGBA(gray, gray, gray)
}

/// 标准 16 色 (VGA 配色)
let termPalette16: [TermColor] = [
    termRGBA(0, 0, 0),         // 0 黑
    termRGBA(170, 0, 0),       // 1 红
    termRGBA(0, 170, 0),       // 2 绿
    termRGBA(170, 85, 0),      // 3 黄
    termRGBA(0, 0, 170),       // 4 蓝
    termRGBA(170, 0, 170),     // 5 品红
    termRGBA(0, 170, 170),     // 6 青
    termRGBA(170, 170, 170),   // 7 白
    termRGBA(85, 85, 85),      // 8 亮黑
    termRGBA(255, 85, 85),     // 9 亮红
    termRGBA(85, 255, 85),     // 10 亮绿
    termRGBA(255, 255, 85),    // 11 亮黄
    termRGBA(85, 85, 255),     // 12 亮蓝
    termRGBA(255, 85, 255),    // 13 亮品红
    termRGBA(85, 255, 255),    // 14 亮青
    termRGBA(255, 255, 255),   // 15 亮白
]

// MARK: - 单元格

struct CellFlags {
    static let bold: UInt8      = 0x01
    static let underline: UInt8 = 0x02
    static let reverse: UInt8   = 0x04
    static let wideCont: UInt8  = 0x08  // 宽字符的第二个格子
}

/// 一个终端格子: 纯值类型, 16 字节, 连续存放在一维数组里, 对 CPU 缓存友好
struct TermCell {
    var scalar: UInt32 = 0        // Unicode scalar, 0 = 空格子
    var fg: TermColor = 0xFFFFFFFF
    var bg: TermColor = 0x000000FF
    var flags: UInt8 = 0
}

/// 粗略的东亚宽字符判定 (中文/日文/韩文/全角占 2 格)
@inline(__always)
func termCharWidth(_ scalar: UInt32) -> Int {
    if scalar < 0x1100 { return 1 }
    switch scalar {
    case 0x1100...0x115F,       // Hangul Jamo
         0x2E80...0x303E,       // CJK 部首/标点
         0x3041...0x33FF,       // 平假名/片假名/CJK
         0x3400...0x4DBF,       // CJK 扩展 A
         0x4E00...0x9FFF,       // CJK 统一表意
         0xA000...0xA4CF,       // 彝文
         0xAC00...0xD7A3,       // Hangul 音节
         0xF900...0xFAFF,       // CJK 兼容
         0xFE30...0xFE4F,       // CJK 兼容形式
         0xFF00...0xFF60,       // 全角 ASCII/标点
         0xFFE0...0xFFE6,       // 全角货币符号
         0x20000...0x3FFFD:     // CJK 扩展 B+
        return 2
    default:
        return 1
    }
}

// MARK: - 终端网格缓冲

/// 脏行快照: 渲染器每帧只拿走变化的行
struct DirtyFrame {
    var rows: [(row: Int, cells: [TermCell])] = []
    var cursorX: Int = 0
    var cursorY: Int = 0
    var cursorVisible: Bool = true
}

final class TerminalBuffer {

    var cols: Int
    var rows: Int
    var cells: [TermCell]

    // 脏行追踪: 布尔数组 + 去重列表, 每字符标记只是数组下标写, 无哈希开销
    // 高频输出时的核心优化: 数据可以每秒来几万次, 但每帧只重绘脏行
    var rowDirty: [Bool] = []
    var dirtyList: [Int] = []

    var cursorX = 0
    var cursorY = 0
    var savedX = 0
    var savedY = 0
    var cursorVisible = true

    // 滚动区域 (DECSTBM), 默认全屏
    var scrollTop = 0
    var scrollBottom = 0

    var wrapMode = true
    var originMode = false
    var insertMode = false

    // 当前 SGR 属性
    var defaultFG: TermColor = 0xE8E8E8FF
    var defaultBG: TermColor = 0x0A0A0EFF
    var curFG: TermColor = 0xE8E8E8FF
    var curBG: TermColor = 0x0A0A0EFF
    var curFlags: UInt8 = 0

    // 备用屏幕 (全屏程序用, 如 vim/htop)
    var altCells: [TermCell]? = nil
    var usingAlt = false

    // 回滚缓冲 (环形, 只在主屏滚动时记录)
    var scrollback: [[TermCell]] = []
    var scrollbackCap = 2000

    var title: String = "TurboTerm"

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        self.scrollBottom = rows - 1
        self.cells = [TermCell](repeating: TermCell(scalar: 0, fg: defaultFG, bg: defaultBG), count: cols * rows)
        self.rowDirty = [Bool](repeating: false, count: rows)
        self.dirtyList.reserveCapacity(rows)
    }

    @inline(__always)
    func index(_ x: Int, _ y: Int) -> Int { return y * cols + x }

    @inline(__always)
    func markRowDirty(_ r: Int) {
        if r >= 0 && r < rows && !rowDirty[r] {
            rowDirty[r] = true
            dirtyList.append(r)
        }
    }

    func markAllDirty() {
        for r in 0..<rows { rowDirty[r] = true }
        dirtyList = Array(0..<rows)
    }

    // MARK: 写入

    /// 在光标处放一个字符 (处理换行/宽字符)
    func put(_ scalar: UInt32) {
        // ASCII 快路径: 万条/秒冲击时 99% 是 ASCII, 跳过所有宽字符判定
        if scalar < 128 {
            if cursorX >= cols {
                if wrapMode { cursorX = 0; lineFeed() } else { cursorX = cols - 1 }
            }
            let i = cursorY * cols + cursorX
            let existing = cells[i]
            if existing.flags & CellFlags.wideCont == 0 && existing.scalar < 128 {
                cells[i] = TermCell(scalar: scalar, fg: curFG, bg: curBG, flags: curFlags)
                markRowDirty(cursorY)
                cursorX += 1
                if cursorX >= cols {
                    if wrapMode { cursorX = 0; lineFeed() } else { cursorX = cols - 1 }
                }
                return
            }
            // 落在宽字符格子上: 走慢路径清理
        }
        putWide(scalar)
    }

    /// 慢路径: 含宽字符/覆盖宽字符的完整处理
    private func putWide(_ scalar: UInt32) {
        let w = termCharWidth(scalar)
        // 宽字符在行尾只剩 1 格时先换行
        if cursorX + w > cols {
            if wrapMode { cursorX = 0; lineFeed() } else { cursorX = cols - w }
        }
        let i = index(cursorX, cursorY)
        // 如果光标落在宽字符的后半格, 把前半格也清空
        if cells[i].flags & CellFlags.wideCont != 0 && cursorX > 0 {
            let p = i - 1
            cells[p] = TermCell(scalar: 0, fg: curFG, bg: curBG)
        }
        // 如果覆盖的是一个宽字符的首格, 把它的后半格清空
        if termCharWidth(cells[i].scalar) == 2 && cursorX + 1 < cols {
            let n = i + 1
            if cells[n].flags & CellFlags.wideCont != 0 {
                cells[n] = TermCell(scalar: 0, fg: curFG, bg: curBG)
            }
        }
        cells[i] = TermCell(scalar: scalar, fg: curFG, bg: curBG, flags: curFlags)
        if w == 2 && cursorX + 1 < cols {
            cells[i + 1] = TermCell(scalar: 0, fg: curFG, bg: curBG, flags: CellFlags.wideCont)
        }
        markRowDirty(cursorY)
        cursorX += w
        if cursorX >= cols {
            if wrapMode { cursorX = 0; lineFeed() }
            else { cursorX = cols - 1 }
        }
    }

    func lineFeed() {
        if cursorY == scrollBottom {
            scrollUp(1)
        } else if cursorY < rows - 1 {
            cursorY += 1
        }
        markRowDirty(cursorY)
    }

    func reverseIndex() {
        if cursorY == scrollTop {
            scrollDown(1)
        } else if cursorY > 0 {
            cursorY -= 1
        }
        markRowDirty(cursorY)
    }

    func carriageReturn() { cursorX = 0 }

    func backspace() { if cursorX > 0 { cursorX -= 1 } }

    func tab() {
        let next = ((cursorX + 8) / 8) * 8
        cursorX = min(next, cols - 1)
    }

    // MARK: 光标

    func moveCursor(dx: Int, dy: Int) {
        cursorX = min(max(cursorX + dx, 0), cols - 1)
        cursorY = min(max(cursorY + dy, 0), rows - 1)
    }

    func setCursor(row: Int, col: Int) {
        var r = row, c = col
        if originMode { r += scrollTop }
        cursorY = min(max(r, 0), rows - 1)
        cursorX = min(max(c, 0), cols - 1)
    }

    func saveCursor() { savedX = cursorX; savedY = cursorY }
    func restoreCursor() { cursorX = savedX; cursorY = savedY }

    // MARK: 滚动

    private func blankCell() -> TermCell {
        return TermCell(scalar: 0, fg: curFG, bg: curBG)
    }

    // MARK: 滚动 (memmove 行块搬移, 高频滚动时的核心优化)

    /// 高速行块搬移: memmove 语义, 内存区域可重叠, 比逐格 Swift 循环快一个数量级
    private func moveRows(srcRow: Int, dstRow: Int, rowCount: Int) {
        guard rowCount > 0 else { return }
        let stride = MemoryLayout<TermCell>.stride
        cells.withUnsafeMutableBufferPointer { bp in
            let base = bp.baseAddress!
            let dst = UnsafeMutableRawPointer(base.advanced(by: dstRow * cols))
            let src = UnsafeRawPointer(base.advanced(by: srcRow * cols))
            dst.copyMemory(from: src, byteCount: rowCount * cols * stride)
        }
    }

    private func clearRow(_ r: Int) {
        let blank = blankCell()
        let base = r * cols
        for c in 0..<cols { cells[base + c] = blank }
    }

    /// 滚动区域上滚 n 行
    func scrollUp(_ n: Int) {
        let count = max(n, 1)
        let top = scrollTop, bottom = scrollBottom
        let fullScreen = (top == 0 && bottom == rows - 1 && !usingAlt)
        for _ in 0..<count {
            if fullScreen {
                // 顶行送入回滚
                let start = top * cols
                pushScrollbackLine(Array(cells[start..<start + cols]))
            }
            // 区域内上移: 一次 memmove 搞定
            if bottom > top {
                moveRows(srcRow: top + 1, dstRow: top, rowCount: bottom - top)
            }
            clearRow(bottom)
        }
        for r in top...bottom { markRowDirty(r) }
    }

    func scrollDown(_ n: Int) {
        let count = max(n, 1)
        let top = scrollTop, bottom = scrollBottom
        for _ in 0..<count {
            if bottom > top {
                moveRows(srcRow: top, dstRow: top + 1, rowCount: bottom - top)
            }
            clearRow(top)
        }
        for r in top...bottom { markRowDirty(r) }
    }

    // MARK: 擦除

    func eraseDisplay(_ mode: Int) {
        switch mode {
        case 1: // 光标到行首
            for r in 0...cursorY {
                let from = (r == cursorY) ? 0 : 0
                let to = (r == cursorY) ? cursorX : cols - 1
                clearRange(row: r, from: from, to: to)
            }
        case 2: // 全屏
            let blank = TermCell(scalar: 0, fg: curFG, bg: defaultBG)
            for i in 0..<cells.count { cells[i] = blank }
            markAllDirty()
        default: // 0: 光标到屏尾
            for r in cursorY..<rows {
                let from = (r == cursorY) ? cursorX : 0
                clearRange(row: r, from: from, to: cols - 1)
            }
        }
    }

    func eraseLine(_ mode: Int) {
        switch mode {
        case 1: clearRange(row: cursorY, from: 0, to: cursorX)
        case 2: clearRange(row: cursorY, from: 0, to: cols - 1)
        default: clearRange(row: cursorY, from: cursorX, to: cols - 1)
        }
    }

    private func clearRange(row: Int, from: Int, to: Int) {
        if row < 0 || row >= rows { return }
        let lo = max(from, 0), hi = min(to, cols - 1)
        if hi < lo { return }
        let blank = TermCell(scalar: 0, fg: curFG, bg: curBG)
        let base = row * cols
        for c in lo...hi { cells[base + c] = blank }
        markRowDirty(row)
    }

    func eraseChars(_ n: Int) {
        let count = min(max(n, 1), cols - cursorX)
        clearRange(row: cursorY, from: cursorX, to: cursorX + count - 1)
    }

    // MARK: 插入 / 删除

    func insertLines(_ n: Int) {
        let count = min(max(n, 1), scrollBottom - cursorY + 1)
        if cursorY < scrollTop || cursorY > scrollBottom { return }
        moveRows(srcRow: cursorY, dstRow: cursorY + count,
                 rowCount: scrollBottom - cursorY - count + 1)
        for r in cursorY..<(cursorY + count) { clearRow(r) }
        for r in scrollTop...scrollBottom { markRowDirty(r) }
    }

    func deleteLines(_ n: Int) {
        let count = min(max(n, 1), scrollBottom - cursorY + 1)
        if cursorY < scrollTop || cursorY > scrollBottom { return }
        moveRows(srcRow: cursorY + count, dstRow: cursorY,
                 rowCount: scrollBottom - cursorY - count + 1)
        for r in (scrollBottom - count + 1)...scrollBottom { clearRow(r) }
        for r in scrollTop...scrollBottom { markRowDirty(r) }
    }

    func insertChars(_ n: Int) {
        let count = min(max(n, 1), cols - cursorX)
        let stride = MemoryLayout<TermCell>.stride
        cells.withUnsafeMutableBufferPointer { bp in
            let base = bp.baseAddress!
            let dst = UnsafeMutableRawPointer(base.advanced(by: cursorY * cols + cursorX + count))
            let src = UnsafeRawPointer(base.advanced(by: cursorY * cols + cursorX))
            dst.copyMemory(from: src, byteCount: (cols - cursorX - count) * stride)
        }
        clearRange(row: cursorY, from: cursorX, to: cursorX + count - 1)
    }

    func deleteChars(_ n: Int) {
        let count = min(max(n, 1), cols - cursorX)
        let stride = MemoryLayout<TermCell>.stride
        cells.withUnsafeMutableBufferPointer { bp in
            let base = bp.baseAddress!
            let dst = UnsafeMutableRawPointer(base.advanced(by: cursorY * cols + cursorX))
            let src = UnsafeRawPointer(base.advanced(by: cursorY * cols + cursorX + count))
            dst.copyMemory(from: src, byteCount: (cols - cursorX - count) * stride)
        }
        clearRange(row: cursorY, from: cols - count, to: cols - 1)
    }

    // MARK: 模式 / 属性

    func setScrollRegion(top: Int, bottom: Int) {
        let t = min(max(top, 0), rows - 1)
        let b = min(max(bottom, 0), rows - 1)
        if t < b {
            scrollTop = t; scrollBottom = b
            setCursor(row: 0, col: 0)
        }
    }

    func resetAttrs() {
        curFG = defaultFG; curBG = defaultBG; curFlags = 0
    }

    func useAltScreen(_ on: Bool) {
        if on == usingAlt { return }
        if on {
            altCells = cells
            usingAlt = true
            cells = [TermCell](repeating: TermCell(scalar: 0, fg: defaultFG, bg: defaultBG), count: cols * rows)
            cursorX = 0; cursorY = 0
            scrollTop = 0; scrollBottom = rows - 1
        } else if let alt = altCells {
            cells = alt
            altCells = nil
            usingAlt = false
        }
        markAllDirty()
    }

    func clearAll() {
        let blank = TermCell(scalar: 0, fg: defaultFG, bg: defaultBG)
        for i in 0..<cells.count { cells[i] = blank }
        cursorX = 0; cursorY = 0
        markAllDirty()
    }

    /// 回滚压入: cap=0 直接跳过; 超限时批量丢弃最旧的, 摊销 O(1)
    /// (原来每次 removeFirst 都是 O(n) 搬移, 万条/秒滚动时是 CPU 热点)
    private func pushScrollbackLine(_ line: [TermCell]) {
        let cap = scrollbackCap
        if cap <= 0 {
            if !scrollback.isEmpty { scrollback.removeAll() }
            return
        }
        scrollback.append(line)
        if scrollback.count > cap + 256 {
            scrollback.removeFirst(scrollback.count - cap)
        }
    }

    // MARK: 尺寸变化 (旋转屏幕/键盘弹起等): 尽量保留可见内容, 不要清屏

    func resize(cols newCols: Int, rows newRows: Int) {
        guard newCols != cols || newRows != rows else { return }
        let oldCells = cells
        let oldCols = cols
        let oldRows = rows
        let oldCursorX = cursorX
        let oldCursorY = cursorY
        // 放不下的旧行送入回滚 (只送新网格装不下的顶部几行, 避免键盘每次弹起都重复送)
        if !usingAlt {
            let dropped = max(0, oldRows - newRows)
            for r in 0..<dropped {
                let start = r * oldCols
                pushScrollbackLine(Array(oldCells[start..<start + oldCols]))
            }
        }
        cols = max(newCols, 1)
        rows = max(newRows, 1)
        cells = [TermCell](repeating: TermCell(scalar: 0, fg: defaultFG, bg: defaultBG), count: cols * rows)
        // 把旧网格底部的内容复制到新网格底部 (保留最近的输出, 光标附近的内容不丢)
        let copyRows = min(oldRows, rows)
        let copyCols = min(oldCols, cols)
        for r in 0..<copyRows {
            let srcRow = oldRows - copyRows + r
            let dstRow = rows - copyRows + r
            for c in 0..<copyCols {
                cells[dstRow * cols + c] = oldCells[srcRow * oldCols + c]
            }
        }
        // 光标保持相对位置 (尽量不跳到左上角)
        cursorX = min(oldCursorX, cols - 1)
        cursorY = rows - copyRows + min(oldCursorY - (oldRows - copyRows), copyRows - 1)
        cursorY = min(max(cursorY, 0), rows - 1)
        rowDirty = [Bool](repeating: false, count: rows)
        dirtyList.removeAll(keepingCapacity: true)
        scrollTop = 0; scrollBottom = rows - 1
        markAllDirty()
    }

    // MARK: 渲染器取走脏帧 (在 parser 串行队列上调用)

    func consumeDirty() -> DirtyFrame {
        var f = DirtyFrame()
        f.cursorX = cursorX
        f.cursorY = cursorY
        f.cursorVisible = cursorVisible
        f.rows.reserveCapacity(dirtyList.count)
        for r in dirtyList {
            rowDirty[r] = false
            let start = r * cols
            f.rows.append((row: r, cells: Array(cells[start..<start + cols])))
        }
        dirtyList.removeAll(keepingCapacity: true)
        return f
    }
}
