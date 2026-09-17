import CTermCore
import Foundation
import Metal
import QuartzCore
import simd

/// One instance per cell. Layout matches `CellInstance` in the shader.
public struct CellInstance {
    public var col: UInt16
    public var row: UInt16
    public var glyph: UInt32
    public var fg: UInt32
    public var bg: UInt32
    public var flags: UInt32
}

public enum InstanceFlags {
    public static let wide: UInt32 = 1
    public static let underline: UInt32 = 2
    public static let strike: UInt32 = 4
    public static let dim: UInt32 = 8
    public static let color: UInt32 = 16
    public static let selected: UInt32 = 32
    public static let hidden: UInt32 = 64
}

/// Per frame constants. Layout matches `Uniforms` in the shader.
public struct Uniforms {
    public var cursor: SIMD4<Float>
    public var cursorColor: SIMD4<Float>
    public var selectionColor: SIMD4<Float>
    public var cellSize: SIMD2<Float>
    public var viewport: SIMD2<Float>
    public var padding: SIMD2<Float>
    public var atlasSize: SIMD2<Float>
}

/// One pipeline, one instanced draw per frame. The CPU side keeps a
/// persistent instance array and rewrites only the rows the core marked
/// dirty; the whole array is then copied into one of three GPU buffers.
public final class Renderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public private(set) var atlas: GlyphAtlas
    public var palette: Palette
    public var paddingPixels: Float
    public var cursorShapeOverride: UInt8?
    /// Set by the view while blinking hides the cursor.
    public var cursorHidden = false

    private let pipeline: MTLRenderPipelineState
    private var instances: [CellInstance] = []
    private var instanceBuffers: [MTLBuffer] = []
    private var frameIndex = 0
    private let inflight = DispatchSemaphore(value: 3)
    private var rectBuffer: MTLBuffer
    private var rectsUploaded = 0
    private var cells: [UInt64] = []
    private var dirty: [UInt64] = []
    private var fresh: [UInt64] = []
    private var cursor = CursorInfo(col: 0, row: 0, shape: 0, blink: false, visible: true)
    public private(set) var cols = 0
    public private(set) var rows = 0

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat, atlas: GlyphAtlas, palette: Palette, paddingPixels: Float,
                library: MTLLibrary? = nil) throws {
        self.device = device
        self.atlas = atlas
        self.palette = palette
        self.paddingPixels = paddingPixels
        queue = device.makeCommandQueue()!
        let lib = try library ?? device.makeLibrary(source: Shaders.source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "cells"
        descriptor.vertexFunction = lib.makeFunction(name: "cell_vertex")
        descriptor.fragmentFunction = lib.makeFunction(name: "cell_fragment")
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        rectBuffer = device.makeBuffer(length: 1024 * MemoryLayout<GlyphRect>.stride, options: .storageModeShared)!
    }

    /// Loads a precompiled library from the app bundle when it is present
    /// and contains both cell functions; anything else falls back to the
    /// runtime compile.
    public static func bundledLibrary(device: MTLDevice) -> MTLLibrary? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("default.metallib"),
              FileManager.default.fileExists(atPath: url.path),
              let library = try? device.makeLibrary(URL: url),
              library.makeFunction(name: "cell_vertex") != nil,
              library.makeFunction(name: "cell_fragment") != nil else { return nil }
        return library
    }

    /// Replaces the atlas, for example after a font size or scale change.
    /// A fresh rect buffer is allocated because up to three frames that
    /// reference the old one may still be in flight.
    public func replaceAtlas(_ newAtlas: GlyphAtlas) {
        atlas = newAtlas
        rectBuffer = device.makeBuffer(length: max(1024, newAtlas.rects.count) * MemoryLayout<GlyphRect>.stride,
                                       options: .storageModeShared)!
        rectsUploaded = 0
        markAllDirty()
    }

    public func gridChanged(cols: Int, rows: Int) {
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        instances = (0..<(cols * rows)).map { i in
            CellInstance(col: UInt16(i % cols), row: UInt16(i / cols), glyph: 0, fg: palette.foreground,
                         bg: palette.background, flags: 0)
        }
        let length = max(1, instances.count) * MemoryLayout<CellInstance>.stride
        instanceBuffers = (0..<3).map { _ in device.makeBuffer(length: length, options: .storageModeShared)! }
        markAllDirty()
    }

    private func markAllDirty() {
        dirty = [UInt64](repeating: .max, count: max(1, (rows + 63) / 64))
    }

    /// Pulls the visible grid, dirty rows and cursor from the terminal
    /// and rebuilds instances for the dirty rows.
    public func update(from terminal: Terminal) {
        if terminal.cols != cols || terminal.rows != rows {
            gridChanged(cols: terminal.cols, rows: terminal.rows)
        }
        cursor = terminal.snapshot(cells: &cells, dirty: &fresh)
        for (i, word) in fresh.enumerated() where i < dirty.count {
            dirty[i] |= word
        }
        let overflow = terminal.overflowColors
        for row in 0..<rows where dirty[row / 64] & (1 << UInt64(row % 64)) != 0 {
            rebuildRow(row, overflow: overflow)
        }
        for i in dirty.indices { dirty[i] = 0 }
    }

    private func rebuildRow(_ row: Int, overflow: [TermRgb]) {
        for col in 0..<cols {
            let cell = Cell(raw: cells[row * cols + col])
            let cf = cell.flags
            var instance = CellInstance(col: UInt16(col), row: UInt16(row), glyph: 0, fg: 0, bg: 0, flags: 0)
            var fg = palette.resolve(cell.fg, overflow: overflow, isForeground: true)
            var bg = palette.resolve(cell.bg, overflow: overflow, isForeground: false)
            if cf.contains(.inverse) { swap(&fg, &bg) }
            instance.fg = fg
            instance.bg = bg
            var flags: UInt32 = 0
            if cell.selected { flags |= InstanceFlags.selected }
            if cf.contains(.wideSpacer) {
                instance.flags = flags | InstanceFlags.hidden
                instances[row * cols + col] = instance
                continue
            }
            var style: GlyphStyle = []
            if cf.contains(.bold) { style.insert(.bold) }
            if cf.contains(.italic) { style.insert(.italic) }
            let ref = atlas.glyph(for: cell.scalar, style: style, wide: cf.contains(.wide))
            instance.glyph = ref.index
            if ref.isColor { flags |= InstanceFlags.color }
            if cf.contains(.wide) { flags |= InstanceFlags.wide }
            if cf.contains(.underline) { flags |= InstanceFlags.underline }
            if cf.contains(.strike) { flags |= InstanceFlags.strike }
            if cf.contains(.dim) { flags |= InstanceFlags.dim }
            instance.flags = flags
            instances[row * cols + col] = instance
        }
    }

    private func uploadRects() {
        let needed = atlas.rects.count * MemoryLayout<GlyphRect>.stride
        if rectBuffer.length < needed {
            rectBuffer = device.makeBuffer(length: needed * 2, options: .storageModeShared)!
            rectsUploaded = 0
        }
        if rectsUploaded < atlas.rects.count {
            atlas.rects.withUnsafeBytes { raw in
                let offset = rectsUploaded * MemoryLayout<GlyphRect>.stride
                memcpy(rectBuffer.contents() + offset, raw.baseAddress! + offset, raw.count - offset)
            }
            rectsUploaded = atlas.rects.count
        }
    }

    private func unpack(_ c: UInt32) -> SIMD4<Float> {
        SIMD4<Float>(Float(c & 0xFF), Float(c >> 8 & 0xFF), Float(c >> 16 & 0xFF), Float(c >> 24 & 0xFF)) / 255
    }

    /// Encodes one frame into `target`. `viewport` is the target size in pixels.
    public func encode(commandBuffer: MTLCommandBuffer, target: MTLTexture) {
        uploadRects()
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        let bgc = unpack(palette.background)
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(bgc.x), green: Double(bgc.y), blue: Double(bgc.z), alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "cells"
        if !instances.isEmpty {
            let buffer = instanceBuffers[frameIndex % 3]
            _ = instances.withUnsafeBytes { raw in memcpy(buffer.contents(), raw.baseAddress!, raw.count) }
            let shape = cursorShapeOverride ?? cursor.shape
            let visible = cursor.visible && !cursorHidden
            var uniforms = Uniforms(
                cursor: SIMD4<Float>(Float(cursor.col), Float(cursor.row), Float(shape), visible ? 1 : 0),
                cursorColor: unpack(palette.cursorColor),
                selectionColor: unpack(palette.selectionBackground),
                cellSize: SIMD2<Float>(Float(atlas.cellWidth), Float(atlas.cellHeight)),
                viewport: SIMD2<Float>(Float(target.width), Float(target.height)),
                padding: SIMD2<Float>(paddingPixels, paddingPixels),
                atlasSize: SIMD2<Float>(Float(atlas.texture.width), Float(atlas.texture.height)))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBuffer(rectBuffer, offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
            encoder.setFragmentTexture(atlas.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
        }
        encoder.endEncoding()
    }

    /// Renders one frame to a drawable. `presented` runs when the frame
    /// reaches the screen, on an arbitrary thread.
    public func render(to drawable: CAMetalDrawable, presented: ((CFTimeInterval) -> Void)? = nil) {
        inflight.wait()
        frameIndex += 1
        guard let commandBuffer = queue.makeCommandBuffer() else {
            inflight.signal()
            return
        }
        commandBuffer.label = "frame \(frameIndex)"
        encode(commandBuffer: commandBuffer, target: drawable.texture)
        let semaphore = inflight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }
        if let presented {
            drawable.addPresentedHandler { _ in presented(CACurrentMediaTime()) }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Renders into a texture and returns its BGRA8 pixels, for tests.
    public func renderOffscreen(width: Int, height: Int) -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        let target = device.makeTexture(descriptor: descriptor)!
        let commandBuffer = queue.makeCommandBuffer()!
        frameIndex += 1
        encode(commandBuffer: commandBuffer, target: target)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { raw in
            target.getBytes(raw.baseAddress!, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return pixels
    }
}
