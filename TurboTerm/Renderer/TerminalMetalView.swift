import Foundation
import SwiftUI
import MetalKit
import QuartzCore

// MARK: - 顶点 (15 floats = 60 字节, 与 Shaders.metal 对应)

struct CellVertex {
var px, py: Float // 设备像素坐标, 左上原点
var u, v: Float // 图集 uv
var cu, cv: Float // 格子内 uv (下划线用)
var fr, fg, fb, fa: Float
var br, bg, bb, ba: Float
var flags: Float // bit1 = 下划线
}

@inline(__always)
func termRGB(_ c: TermColor) -> (Float, Float, Float) {
return (Float((c >> 24) & 0xFF) / 255.0,
Float((c >> 16) & 0xFF) / 255.0,
Float((c >> 8) & 0xFF) / 255.0)
}

// MARK: - 设置

struct TermSettings: Equatable {
var fontSize: CGFloat = 16 // 字体大小 pt
var renderScale: CGFloat = 2 // 字体分辨率: 1x / 2x / 3x
var fps: Int = 120 // 60 / 120
var scrollbackCap: Int = 2000 // 回滚行数 (0=关)
var perfMode: Bool = false // 性能模式: 锁60帧 + 分辨率降到1x
}

extension DirtyFrame {
/// 合并两帧脏数据: 同一行后到的覆盖先到的 (只影响显示, 不丢数据)
mutating func merge(_ other: DirtyFrame) {
if other.rows.isEmpty { return}
var map = [Int: [TermCell]](minimumCapacity: rows.count + other.rows.count)
for (r, cells) in rows { map[r] = cells}
for (r, cells) in other.rows { map[r] = cells}
rows = map.map { ($0.key, $0.value)}
cursorX = other.cursorX
cursorY = other.cursorY
cursorVisible = other.cursorVisible
}
}

// MARK: - 控制器

/// 线程模型 (四线程流水线):
/// main: UI + Metal 提交 (只做编码, 不做重活)
/// turboterm.parser: VT 解析 + 网格状态 (有状态, 串行)
/// turboterm.prep: 顶点填充 + GPU 上传 (后台, 三重缓冲)
/// turboterm.shell: 后端命令执行
final class TerminalController: ObservableObject {
let buffer: TerminalBuffer
let parser: VTParser
let queue = DispatchQueue(label: "turboterm.parser", qos:.userInteractive)
weak var renderer: TermRenderer?
private var backend: TerminalBackend?

/// 输入背压合并: 生产者再快, parser 队列里也只有一个待处理块, 不会堆积
private var pendingInput = Data()
private let inputLock = NSLock()

var pendingSettings = TermSettings()
/// 是否主窗口: 主窗口=false才进省电模式; 从窗口恒为省电 (1fps+160p)
var isMasterPane = true

init(cols: Int, rows: Int) {
buffer = TerminalBuffer(cols: cols, rows: rows)
parser = VTParser(buffer: buffer)
}

func start(backend: TerminalBackend) {
self.backend = backend
backend.start { [weak self] data in self?.receive(data)}
}

func stop() { backend?.stop()}

func receive(_ data: Data) {
inputLock.lock()
pendingInput.append(data)
inputLock.unlock()
queue.async { [weak self] in self?.drainInput()}
}

private func drainInput() {
inputLock.lock()
let d = pendingInput
pendingInput.removeAll(keepingCapacity: true)
inputLock.unlock()
if !d.isEmpty { parser.feed(d)}
}

func send(_ string: String) {
backend?.send(Data(string.utf8))
}

func sendBytes(_ bytes: [UInt8]) {
backend?.send(Data(bytes))
}

/// 渲染线程调用: 原子地取走脏帧 (在 parser 队列上同步执行, 极快)
func drainSync() -> DirtyFrame {
return queue.sync { buffer.consumeDirty()}
}

func resizeSync(cols: Int, rows: Int) {
queue.sync { buffer.resize(cols: cols, rows: rows)}
}

/// 主线程调用: 应用渲染设置
func applySettings(_ s: TermSettings) {
pendingSettings = s
buffer.scrollbackCap = s.scrollbackCap
renderer?.applySettings(s, lowPower: !isMasterPane)
}
}

// MARK: - Metal 渲染器 v2

/// 高频优化策略:
/// 1. 三重缓冲 + 后台预处理: 顶点填充和 GPU 上传在 prep 线程做,
/// 主线程只做编码提交; 预处理跟不上时脏帧自动合并, 永不堆积。
/// 2. 脏行追踪 + vsync 合并: 10k 条/秒进来, 每帧也只画一次。
/// 3. 字形图集 + 启动预热: 高频字符零现场光栅化。
/// 4. memmove 行块搬移 (见 TerminalBuffer)。
/// 5. 输入背压合并 (见 TerminalController)。
/// 以上全是"不影响运行"的优化: 数据一字不丢, 只合并显示。
final class TermRenderer: NSObject, MTKViewDelegate {

let device: MTLDevice
let commandQueue: MTLCommandQueue
let pipeline: MTLRenderPipelineState
let controller: TerminalController
weak var mtkView: MTKView?

var atlas: GlyphAtlas
let atlasLock = NSLock() // 只保护 atlas 引用的替换
var fontSize: CGFloat = 16
var renderScale: CGFloat = 2
var cachedWhiteUV: (u: Float, v: Float) = (0, 0)

var cols = 0
var rows = 0
var cellW = 0
var cellH = 0

// 三重缓冲: prep 写 writeIndex, main 读 readIndex, 永不打架
var vertexBuffers: [MTLBuffer] = []
/// 每个顶点缓冲对应的图集纹理 (顶点里的 UV 是按这个纹理烘焙的, 必须配对使用;
/// applySettings 换图集时, 旧缓冲的旧纹理继续有效, 不会串)
var bufferTextures: [MTLTexture?] = [nil, nil, nil]
var readIndex = 0
var writeIndex = 0
/// 几何版本号: rebuildGeometry 递增; prep 发现版本号变了就丢弃本次结果,
/// 防止"旧尺寸算出的顶点 + 新尺寸的缓冲"混用
var geometryGen = 0
let bufLock = NSLock()

var cpuVerts: [CellVertex] = []
var indexBuffer: MTLBuffer?
var cursorBuffer: MTLBuffer?
var geometryReady = false

// 后台预处理
let prepQueue = DispatchQueue(label: "turboterm.prep", qos:.userInitiated)
var prepBusy = false
var pendingFrame: DirtyFrame?
let pendingLock = NSLock()

var lastDrawableSize: CGSize = .zero
var cursorInfo = (x: 0, y: 0, visible: true)

// 省电模式 (多开从窗口): 1fps + 强制 160p drawable, GPU 只画这点像素
var lowPowerMode = false

init(device: MTLDevice, controller: TerminalController) {
self.device = device
self.controller = controller
self.commandQueue = device.makeCommandQueue()!

let scale = min(UIScreen.main.scale, 2)
self.atlas = GlyphAtlas(device: device, fontSize: 16, scale: scale)
self.renderScale = scale
self.cellW = atlas.cellW
self.cellH = atlas.cellH
self.cachedWhiteUV = atlas.whiteUV

let lib = device.makeDefaultLibrary()!
let pd = MTLRenderPipelineDescriptor()
pd.vertexFunction = lib.makeFunction(name: "term_vertex")
pd.fragmentFunction = lib.makeFunction(name: "term_fragment")
pd.colorAttachments[0].pixelFormat = .bgra8Unorm

let vd = MTLVertexDescriptor()
func attr(_ i: Int, _ fmt: MTLVertexFormat, _ off: Int) {
vd.attributes[i].format = fmt
vd.attributes[i].offset = off
vd.attributes[i].bufferIndex = 0
}
attr(0,.float2, 0) // pos
attr(1,.float2, 8) // uv
attr(2,.float2, 16) // cellUV
attr(3,.float4, 24) // fg
attr(4,.float4, 40) // bg
attr(5,.float, 56) // flags
vd.layouts[0].stride = MemoryLayout<CellVertex>.stride
vd.layouts[0].stepFunction = .perVertex
pd.vertexDescriptor = vd

self.pipeline = try! device.makeRenderPipelineState(descriptor: pd)
super.init()
prewarmAtlas()
}

// MARK: 设置 (主线程调用)

func applySettings(_ s: TermSettings, lowPower: Bool) {
lowPowerMode = lowPower
// 省电(多开从窗口): 1fps + 160p + 最低分辨率; 性能模式: 主窗口 10fps + 最低分辨率
let scale: CGFloat
let fps: Int
if lowPower {
scale = 1
fps = 1
} else if s.perfMode {
scale = 1
fps = 10
} else {
scale = s.renderScale
fps = s.fps
}
fontSize = s.fontSize
renderScale = scale
atlasLock.lock()
atlas = GlyphAtlas(device: device, fontSize: s.fontSize, scale: scale)
cellW = atlas.cellW
cellH = atlas.cellH
cachedWhiteUV = atlas.whiteUV
atlasLock.unlock()
prewarmAtlas()
mtkView?.preferredFramesPerSecond = fps
viewDidResize(to: lastDrawableSize)
}

/// 启动时把常用字形先烘焙好, 高频冲击时零现场光栅化
private func prewarmAtlas() {
atlasLock.lock()
let at = atlas
atlasLock.unlock()
prepQueue.async {
for s: UInt32 in 32...126 { _ = at.entry(for: s, bold: false)}
for s: UInt32 in 32...126 { _ = at.entry(for: s, bold: true)}
let cjk = "的一是不了我有在人这中大为上个国和地到说时要就出会可也你对生能而子那得于着下自之年过发后作里用道行所然家种事成方多经么去法学如都同现当没动面起看定天分还进好小部其些主系只没：，。！？、；：“”‘’（）《》0123456789"
for ch in cjk.unicodeScalars { _ = at.entry(for: ch.value, bold: false)}
}
}

// MARK: 几何

func viewDidResize(to drawableSize: CGSize) {
lastDrawableSize = drawableSize
let w = Int(drawableSize.width), h = Int(drawableSize.height)
guard w > 0 && h > 0 else { return}
let newCols = max(w / cellW, 1)
let newRows = max(h / cellH, 1)
if geometryReady && newCols == cols && newRows == rows { return}
controller.resizeSync(cols: newCols, rows: newRows)
rebuildGeometry(cols: newCols, rows: newRows)
}

private func rebuildGeometry(cols: Int, rows: Int) {
self.cols = cols
self.rows = rows
let cellCount = cols * rows
cpuVerts = [CellVertex](repeating: CellVertex(px: 0, py: 0, u: 0, v: 0, cu: 0, cv: 0,
fr: 0, fg: 0, fb: 0, fa: 1,
br: 0, bg: 0, bb: 0, ba: 1, flags: 0),
count: cellCount * 4)
let stride = MemoryLayout<CellVertex>.stride
bufLock.lock()
vertexBuffers = (0..<3).map { i in
let b = device.makeBuffer(length: cellCount * 4 * stride, options:.storageModeShared)!
b.label = "TermVerts\(i)"
return b
}
bufferTextures = [nil, nil, nil]
readIndex = 0
writeIndex = 0
geometryGen += 1
bufLock.unlock()

var idx = [UInt32]()
idx.reserveCapacity(cellCount * 6)
for i in 0..<cellCount {
let b = UInt32(i * 4)
idx.append(contentsOf: [b, b + 1, b + 2, b + 2, b + 1, b + 3])
}
indexBuffer = device.makeBuffer(bytes: idx, length: idx.count * 4, options:.storageModeShared)
indexBuffer?.label = "TermIdx"

cursorBuffer = device.makeBuffer(length: 4 * stride, options:.storageModeShared)
cursorBuffer?.label = "TermCursor"
geometryReady = true
}

// MARK: 顶点填充 (prep 线程)

private func fillCell(row r: Int, col c: Int, cell: TermCell, atlas at: GlyphAtlas) {
let base = (r * cols + c) * 4
let x0 = Float(c * cellW), y0 = Float(r * cellH)

var fgC = cell.fg, bgC = cell.bg
if cell.flags & CellFlags.reverse != 0 { swap(&fgC, &bgC)}
let (fr, fgg, fb) = termRGB(fgC)
let (br, bgg, bb) = termRGB(bgC)
let ul: Float = (cell.flags & CellFlags.underline) != 0 ? 2.0 : 0.0

var u0: Float, vTop: Float, u1: Float, vBot: Float
var qw = Float(cellW)
if cell.scalar == 0 {
u0 = at.emptyUV.u; vTop = at.emptyUV.v
u1 = at.emptyUV.u; vBot = at.emptyUV.v
} else {
let bold = (cell.flags & CellFlags.bold) != 0
let e = at.entry(for: cell.scalar, bold: bold)
let uv = at.uv(for: e)
u0 = uv.u0; vTop = uv.v0; u1 = uv.u1; vBot = uv.v1
qw = Float(e.w)
}
let x1 = x0 + qw, y1 = y0 + Float(cellH)

cpuVerts[base] = CellVertex(px: x0, py: y0, u: u0, v: vTop, cu: 0, cv: 0,
fr: fr, fg: fgg, fb: fb, fa: 1,
br: br, bg: bgg, bb: bb, ba: 1, flags: ul)
cpuVerts[base + 1] = CellVertex(px: x1, py: y0, u: u1, v: vTop, cu: 1, cv: 0,
fr: fr, fg: fgg, fb: fb, fa: 1,
br: br, bg: bgg, bb: bb, ba: 1, flags: ul)
cpuVerts[base + 2] = CellVertex(px: x0, py: y1, u: u0, v: vBot, cu: 0, cv: 1,
fr: fr, fg: fgg, fb: fb, fa: 1,
br: br, bg: bgg, bb: bb, ba: 1, flags: ul)
cpuVerts[base + 3] = CellVertex(px: x1, py: y1, u: u1, v: vBot, cu: 1, cv: 1,
fr: fr, fg: fgg, fb: fb, fa: 1,
br: br, bg: bgg, bb: bb, ba: 1, flags: ul)
}

// MARK: 预处理调度

private func kickPrep() {
pendingLock.lock()
guard !prepBusy, let frame = pendingFrame else {
pendingLock.unlock()
return
}
pendingFrame = nil
prepBusy = true
pendingLock.unlock()

atlasLock.lock()
let at = atlas
atlasLock.unlock()

prepQueue.async { [weak self] in
self?.prepFrame(frame, atlas: at)
}
}

private func prepFrame(_ frame: DirtyFrame, atlas at: GlyphAtlas) {
bufLock.lock()
let gen = geometryGen
let wi = writeIndex
let vb = wi < vertexBuffers.count ? vertexBuffers[wi] : nil
bufLock.unlock()
guard let vb = vb else { finishPrep(); return}

let dst = vb.contents().bindMemory(to: CellVertex.self, capacity: cols * rows * 4)
cpuVerts.withUnsafeBufferPointer { src in
guard let sbase = src.baseAddress else { return}
for (r, cells) in frame.rows {
guard r >= 0 && r < rows else { continue}
let n = min(cols, cells.count)
for c in 0..<n { fillCell(row: r, col: c, cell: cells[c], atlas: at)}
let rowStart = r * cols * 4
dst.advanced(by: rowStart).update(from: sbase.advanced(by: rowStart), count: cols * 4)
}
}

bufLock.lock()
// 几何版本变了 (中途 rebuildGeometry), 本次结果作废, 不更新 readIndex
if gen == geometryGen && wi < vertexBuffers.count {
readIndex = wi
writeIndex = (writeIndex + 1) % vertexBuffers.count
bufferTextures[wi] = at.texture
}
bufLock.unlock()
finishPrep()
}

private func finishPrep() {
pendingLock.lock()
prepBusy = false
let more = pendingFrame != nil
pendingLock.unlock()
if more { kickPrep()}
}

// MARK: MTKViewDelegate (主线程: 只做提交)

func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

func draw(in view: MTKView) {
guard geometryReady, vertexBuffers.count == 3,
let drawable = view.currentDrawable,
let rpd = view.currentRenderPassDescriptor else { return}

// 取脏帧 + 更新光标 (快)
let frame = controller.drainSync()
cursorInfo = (frame.cursorX, frame.cursorY, frame.cursorVisible)

// 脏行攒起来, 后台慢慢预处理; 跟不上就合并, 永不堆积
if !frame.rows.isEmpty {
pendingLock.lock()
if var p = pendingFrame { p.merge(frame); pendingFrame = p}
else { pendingFrame = frame}
pendingLock.unlock()
kickPrep()
}

// 渲染最新已完成的缓冲
bufLock.lock()
let ri = readIndex
let tex = ri < bufferTextures.count ? bufferTextures[ri] : nil
bufLock.unlock()
let vb = vertexBuffers[ri]

guard let cmd = commandQueue.makeCommandBuffer(),
let enc = cmd.makeRenderCommandEncoder(descriptor: rpd),
let ib = indexBuffer else { return}
enc.setRenderPipelineState(pipeline)
enc.setVertexBuffer(vb, offset: 0, index: 0)
var vp = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
enc.setVertexBytes(&vp, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
// 用和顶点缓冲配对的纹理 (prep 时存的); 还没预处理完时回退到当前图集
enc.setFragmentTexture(tex ?? atlasTexture(), index: 0)
enc.drawIndexedPrimitives(type:.triangle, indexCount: cols * rows * 6,
indexType:.uint32, indexBuffer: ib, indexBufferOffset: 0)

// 光标 (4 个顶点, 主线程直接填, 开销可忽略)
let blinkOn = fmod(CACurrentMediaTime(), 1.06) < 0.53
if cursorInfo.visible && blinkOn,
let cb = cursorBuffer,
cursorInfo.x >= 0 && cursorInfo.x < cols &&
cursorInfo.y >= 0 && cursorInfo.y < rows {
let x0 = Float(cursorInfo.x * cellW), y0 = Float(cursorInfo.y * cellH)
let x1 = x0 + Float(cellW), y1 = y0 + Float(cellH)
let wu = cachedWhiteUV
let cv = cb.contents().bindMemory(to: CellVertex.self, capacity: 4)
let mk = { (x: Float, y: Float, cu: Float, cvv: Float) -> CellVertex in
CellVertex(px: x, py: y, u: wu.u, v: wu.v, cu: cu, cv: cvv,
fr: 1, fg: 1, fb: 1, fa: 1,
br: 1, bg: 1, bb: 1, ba: 1, flags: 0)
}
cv[0] = mk(x0, y0, 0, 0); cv[1] = mk(x1, y0, 1, 0)
cv[2] = mk(x0, y1, 0, 1); cv[3] = mk(x1, y1, 1, 1)
enc.setVertexBuffer(cb, offset: 0, index: 0)
enc.drawPrimitives(type:.triangleStrip, vertexStart: 0, vertexCount: 4)
}

enc.endEncoding()
cmd.present(drawable)
cmd.commit()
}

private func atlasTexture() -> MTLTexture {
atlasLock.lock()
defer { atlasLock.unlock()}
return atlas.texture
}
}

// MARK: - MTKView 封装

final class MetalTermView: MTKView, UIKeyInput {
let renderer: TermRenderer
/// 直接键盘输入回调: 文字 -> 发给主窗口 (经 PaneManager 广播)
var onTextInput: ((String) -> Void)?
/// 退格键回调: 发 0x7F
var onDelete: (() -> Void)?

init(controller: TerminalController) {
guard let device = MTLCreateSystemDefaultDevice() else {
fatalError("此设备不支持 Metal")
}
self.renderer = TermRenderer(device: device, controller: controller)
super.init(frame:.zero, device: device)
self.renderer.mtkView = self
controller.renderer = renderer
// 应用该窗格待定的设置 (字体/分辨率等); 从窗口直接进省电模式
renderer.applySettings(controller.pendingSettings, lowPower: !controller.isMasterPane)
self.delegate = renderer
self.colorPixelFormat = .bgra8Unorm
self.framebufferOnly = true
self.isPaused = false
self.enableSetNeedsDisplay = false
self.preferredFramesPerSecond = controller.pendingSettings.fps
self.clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1.0)
// 终端用 ASCII 键盘: 命令都是 ASCII, 避免拼音输入法标记文本的复杂性
self.keyboardType = .asciiCapable
}

required init(coder: NSCoder) {
fatalError("init(coder:) 未实现")
}

// MARK: - 直接键盘输入 (终端即输入框, 点终端弹键盘)

override var canBecomeFirstResponder: Bool { true }

var hasText: Bool { true }

func insertText(_ text: String) {
onTextInput?(text)
}

func deleteBackward() {
onDelete?()
}

@objc func focusKeyboard() {
becomeFirstResponder()
}

override func layoutSubviews() {
super.layoutSubviews()
if renderer.lowPowerMode {
// 强制 160p 高的 drawable (按视图宽高比算宽度), 图层自动放大显示,
// GPU 每帧只画这点像素, 几乎零开销
let aspect = bounds.width / max(bounds.height, 1)
let size = CGSize(width: max(round(160 * aspect), 1), height: 160)
if self.drawableSize != size {
self.drawableSize = size
}
}
renderer.viewDidResize(to: self.drawableSize)
}
}

struct TerminalMetalView: UIViewRepresentable {
@ObservedObject var controller: TerminalController
/// 直接输入: 文字发给主窗口 (调用方负责广播)
var onTextInput: (String) -> Void = { _ in }
/// 退格键
var onDelete: () -> Void = { }

func makeUIView(context: Context) -> MetalTermView {
let v = MetalTermView(controller: controller)
v.onTextInput = onTextInput
v.onDelete = onDelete
// 点终端即弹键盘, 终端本身就是输入框
let tap = UITapGestureRecognizer(target: v, action: #selector(MetalTermView.focusKeyboard))
v.addGestureRecognizer(tap)
return v
}

func updateUIView(_ uiView: MetalTermView, context: Context) {
uiView.onTextInput = onTextInput
uiView.onDelete = onDelete
}
}
