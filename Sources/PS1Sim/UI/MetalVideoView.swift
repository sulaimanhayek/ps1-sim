import SwiftUI
import MetalKit

/// Draws the core's framebuffer as a single textured quad, letterboxed to the
/// game's aspect ratio. The shader is compiled from source at runtime so the
/// package needs no .metal build step.
final class MetalVideoView: MTKView, MTKViewDelegate {

    private let store: FrameStore
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var linearSampler: MTLSamplerState?
    private var nearestSampler: MTLSamplerState?
    private var lastGeneration: UInt64 = 0
    private var textureWidth = 0
    private var textureHeight = 0
    private var contentAspect: Float = 4.0 / 3.0

    var smoothScaling = true
    var integerScaling = false
    var scanlines = false

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        float2 scale;
        float  scanlineStrength;
        float  sourceHeight;
    };

    vertex VertexOut ps1_vertex(uint vid [[vertex_id]],
                                constant Uniforms &u [[buffer(0)]]) {
        float2 positions[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
        float2 uvs[4]       = { float2(0, 1),   float2(1, 1),  float2(0, 0),  float2(1, 0) };
        VertexOut out;
        out.position = float4(positions[vid] * u.scale, 0.0, 1.0);
        out.uv = uvs[vid];
        return out;
    }

    fragment float4 ps1_fragment(VertexOut in [[stage_in]],
                                 constant Uniforms &u [[buffer(0)]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler samp [[sampler(0)]]) {
        float4 color = tex.sample(samp, in.uv);
        if (u.scanlineStrength > 0.0) {
            float line = fract(in.uv.y * u.sourceHeight);
            float dim = 1.0 - u.scanlineStrength * smoothstep(0.5, 1.0, abs(line - 0.5) * 2.0);
            color.rgb *= dim;
        }
        return color;
    }
    """

    private struct Uniforms {
        var scaleX: Float
        var scaleY: Float
        var scanlineStrength: Float
        var sourceHeight: Float
    }

    init(store: FrameStore) {
        self.store = store
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        configure()
    }

    required init(coder: NSCoder) { fatalError("not supported") }

    private func configure() {
        guard let device else { return }
        commandQueue = device.makeCommandQueue()
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        // Draw on the display's own cadence; the emulator writes frames independently.
        preferredFramesPerSecond = 60
        isPaused = false
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        delegate = self

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "ps1_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "ps1_fragment")
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("PS1Sim: shader compilation failed: \(error)")
        }

        let linear = MTLSamplerDescriptor()
        linear.minFilter = .linear
        linear.magFilter = .linear
        linear.sAddressMode = .clampToEdge
        linear.tAddressMode = .clampToEdge
        linearSampler = device.makeSamplerState(descriptor: linear)

        let nearest = MTLSamplerDescriptor()
        nearest.minFilter = .nearest
        nearest.magFilter = .nearest
        nearest.sAddressMode = .clampToEdge
        nearest.tAddressMode = .clampToEdge
        nearestSampler = device.makeSamplerState(descriptor: nearest)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        uploadLatestFrame()
        guard let pipeline,
              let commandQueue,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }

        if let texture {
            var uniforms = makeUniforms()
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(smoothScaling ? linearSampler : nearestSampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    private func uploadLatestFrame() {
        store.withLatest(since: &lastGeneration) { pixels, width, height, aspect in
            contentAspect = aspect
            if texture == nil || textureWidth != width || textureHeight != height {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
                descriptor.usage = .shaderRead
                descriptor.storageMode = .managed
                texture = device?.makeTexture(descriptor: descriptor)
                textureWidth = width
                textureHeight = height
            }
            texture?.replace(region: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0,
                             withBytes: pixels,
                             bytesPerRow: width * 4)
        }
    }

    /// Letterbox: scale the quad so the picture keeps its aspect ratio inside the view.
    private func makeUniforms() -> Uniforms {
        let viewWidth = Float(max(drawableSize.width, 1))
        let viewHeight = Float(max(drawableSize.height, 1))
        let viewAspect = viewWidth / viewHeight
        var scaleX: Float = 1
        var scaleY: Float = 1
        if viewAspect > contentAspect {
            scaleX = contentAspect / viewAspect
        } else {
            scaleY = viewAspect / contentAspect
        }

        if integerScaling, textureHeight > 0 {
            let targetHeight = viewHeight * scaleY
            let factor = max(1, floor(targetHeight / Float(textureHeight)))
            let snappedHeight = factor * Float(textureHeight)
            let snappedWidth = snappedHeight * contentAspect
            if snappedWidth <= viewWidth {
                scaleX = snappedWidth / viewWidth
                scaleY = snappedHeight / viewHeight
            }
        }

        return Uniforms(scaleX: scaleX,
                        scaleY: scaleY,
                        scanlineStrength: scanlines ? 0.35 : 0.0,
                        sourceHeight: Float(max(textureHeight, 1)))
    }
}

/// SwiftUI wrapper. Keeps render options in sync with Settings.
struct VideoSurface: NSViewRepresentable {
    let store: FrameStore
    var smoothScaling: Bool
    var integerScaling: Bool
    var scanlines: Bool

    func makeNSView(context: Context) -> MetalVideoView {
        let view = MetalVideoView(store: store)
        view.smoothScaling = smoothScaling
        view.integerScaling = integerScaling
        view.scanlines = scanlines
        return view
    }

    func updateNSView(_ view: MetalVideoView, context: Context) {
        view.smoothScaling = smoothScaling
        view.integerScaling = integerScaling
        view.scanlines = scanlines
    }
}
