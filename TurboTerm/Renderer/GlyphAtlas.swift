import Foundation
import Metal
import CoreText
import UIKit

/// 字形图集: 每个字符只用 CoreText 光栅化一次, 烘焙进 Metal 纹理,
/// 之后渲染只是贴一张小图 —— 这是高频文字场景下最重要的优化。
/// 版式: R8 纹理存灰度 alpha, shelf packing 打包。
final class GlyphAtlas {

    struct Entry {
        var px: Int, py: Int     // 在图集中的像素位置
        var w: Int, h: Int       // 像素尺寸 (宽字符 w = 2*cellW)
    }

    let device: MTLDevice
    let texture: MTLTexture
    let atlasSize = 2048

    let cellW: Int      // 设备像素
    let cellH: Int
    let font: CTFont
    let boldFont: CTFont

    private var entries: [UInt64: Entry] = [:]
    private var packX = 1
    private var packY = 1
    private var packRowH = 0

    /// 预留的 1x1 纯白像素 (画光标块用)
    let whiteUV: (u: Float, v: Float)
    /// 预留的 1x1 纯黑像素 (空格子用, alpha=0 只显示背景)
    let emptyUV: (u: Float, v: Float)

    init(device: MTLDevice, fontSize: CGFloat, scale: CGFloat) {
        self.device = device
        let pxSize = fontSize * scale

        // iOS 自带等宽字体 Menlo; 拿不到就回退到系统等宽
        var f = CTFontCreateWithName("Menlo" as CFString, pxSize, nil)
        var ch: UniChar = 77 // 'M'
        var g = CGGlyph()
        if !CTFontGetGlyphsForCharacters(f, &ch, &g, 1) || g == 0 {
            let ui = UIFont.monospacedSystemFont(ofSize: pxSize, weight: .regular)
            f = CTFontCreateWithName(ui.fontName as CFString, pxSize, nil)
        }
        self.font = f
        // 粗体: 用符号特征派生
        if let bf = CTFontCreateCopyWithSymbolicTraits(f, pxSize, nil, .boldTrait, .boldTrait) {
            self.boldFont = bf
        } else {
            self.boldFont = f
        }

        CTFontGetGlyphsForCharacters(f, &ch, &g, 1)
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(f, .horizontal, &g, &adv, 1)
        let ascent = CTFontGetAscent(f)
        let descent = CTFontGetDescent(f)
        let leading = CTFontGetLeading(f)
        self.cellW = max(Int(ceil(adv.width)), 1)
        self.cellH = max(Int(ceil(ascent + descent + leading)), 1)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: atlasSize, height: atlasSize, mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        self.texture = device.makeTexture(descriptor: desc)!
        self.texture.label = "GlyphAtlas"

        // (0,0) 处放一个白色像素, (1,0) 处放一个黑色像素
        var white: UInt8 = 255
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &white, bytesPerRow: 1)
        var black: UInt8 = 0
        texture.replace(region: MTLRegionMake2D(1, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &black, bytesPerRow: 1)
        let s = Float(atlasSize)
        self.whiteUV = (u: 0.5 / s, v: 0.5 / s)
        self.emptyUV = (u: 1.5 / s, v: 0.5 / s)
    }

    @inline(__always)
    private func key(_ scalar: UInt32, _ bold: Bool) -> UInt64 {
        return (UInt64(scalar) << 1) | (bold ? 1 : 0)
    }

    /// 取字形在图集中的位置 (没有就现场烘焙)
    func entry(for scalar: UInt32, bold: Bool) -> Entry {
        let k = key(scalar, bold)
        if let e = entries[k] { return e }
        let e = rasterize(scalar: scalar, bold: bold)
        entries[k] = e
        return e
    }

    private func resetAtlas() {
        entries.removeAll(keepingCapacity: true)
        packX = 1; packY = 1; packRowH = 0
        // 注意: 旧纹理内容作废, 所有字形会在下次使用时重新烘焙
    }

    private func rasterize(scalar: UInt32, bold: Bool) -> Entry {
        let wide = termCharWidth(scalar) == 2
        let w = wide ? cellW * 2 : cellW
        let h = cellH

        // shelf packing
        if packX + w + 1 > atlasSize {
            packX = 1
            packY += packRowH + 1
            packRowH = 0
        }
        if packY + h + 1 > atlasSize {
            resetAtlas()  // 图集满了: 清空重来 (极少发生)
        }
        let ex = packX, ey = packY
        packX += w + 1
        packRowH = max(packRowH, h)

        // 灰度位图上下文, CoreGraphics 原点在左下
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                 bitsPerComponent: 8, bytesPerRow: w,
                                 space: colorSpace,
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            return Entry(px: 0, py: 0, w: w, h: h)
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)

        let f = bold ? boldFont : font
        // scalar -> UTF-16
        var units: [UniChar] = []
        if scalar < 0x10000 {
            units = [UniChar(scalar)]
        } else {
            let v = scalar - 0x10000
            units = [UniChar(0xD800 + (v >> 10)), UniChar(0xDC00 + (v & 0x3FF))]
        }
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        let got = CTFontGetGlyphsForCharacters(f, units, &glyphs, units.count)

        if got && glyphs[0] != 0 {
            var pos = CGPoint(x: 0, y: CTFontGetDescent(f))
            // 宽字符可能超出 cellW, 居中一点防止裁切
            CTFontDrawGlyphs(f, &glyphs, &pos, units.count, ctx)
        } else {
            // 缺字: 画个空心方块, 方便发现问题
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setLineWidth(1)
            ctx.stroke(CGRect(x: 2, y: 2, width: w - 4, height: h - 4))
        }

        if let data = ctx.data {
            texture.replace(region: MTLRegionMake2D(ex, ey, w, h), mipmapLevel: 0,
                            withBytes: data, bytesPerRow: w)
        }
        return Entry(px: ex, py: ey, w: w, h: h)
    }

    /// 字形 UV: CG 位图内存是 top-down 的 (第 0 行 = 字形顶部, 真机截图证实),
    /// Metal 纹理 v=0 采样第 0 行, 所以 quad 上沿取 v 小的一端。
    /// 注意: 只需垂直翻转 (vTop/vBot 对调), u 方向保持原样;
    /// 若把 u0/u1 也对调会变成 180° 旋转, 引入水平镜像 (b 会显示成 d)。
    @inline(__always)
    func uv(for e: Entry) -> (u0: Float, v0: Float, u1: Float, v1: Float) {
        let s = Float(atlasSize)
        let u0 = (Float(e.px) + 0.5) / s
        let u1 = (Float(e.px + e.w) - 0.5) / s
        // quad 上沿取 v 小的一端 (字形顶部), 下沿取 v 大的一端 (字形底部)
        let vTop = (Float(e.py) + 0.5) / s       // quad 上沿
        let vBot = (Float(e.py + e.h) - 0.5) / s // quad 下沿
        return (u0, vTop, u1, vBot)
    }
}
