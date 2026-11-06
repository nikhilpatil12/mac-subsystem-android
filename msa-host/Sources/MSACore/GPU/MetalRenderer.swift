import AppKit
import Metal
import QuartzCore
import simd

public struct MSAVertex {
    public var position: SIMD2<Float>
    public var texCoords: SIMD2<Float>

    public init(position: SIMD2<Float>, texCoords: SIMD2<Float>) {
        self.position = position
        self.texCoords = texCoords
    }
}

public final class MetalRenderer: @unchecked Sendable {
    public static let shared = MetalRenderer()

    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    private var currentTexture: MTLTexture?
    private var textureWidth: Int = 0
    private var textureHeight: Int = 0
    private let lock = NSLock()

    private let mslSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoords;
    };

    struct MSAVertex {
        float2 position;
        float2 texCoords;
    };

    vertex VertexOut msa_vertex(uint vertexID [[vertex_id]], constant MSAVertex* vertices [[buffer(0)]]) {
        VertexOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.texCoords = vertices[vertexID].texCoords;
        return out;
    }

    fragment float4 msa_fragment(VertexOut in [[stage_in]],
                                 texture2d<float, access::sample> tex [[texture(0)]],
                                 sampler smp [[sampler(0)]]) {
        return tex.sample(smp, in.texCoords);
    }
    """

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let dev = device, let queue = dev.makeCommandQueue() else {
            return nil
        }
        self.device = dev
        self.commandQueue = queue
        setupPipeline()
    }

    private func setupPipeline() {
        do {
            let library = try device.makeLibrary(source: mslSource, options: nil)
            guard let vertexFunc = library.makeFunction(name: "msa_vertex"),
                  let fragmentFunc = library.makeFunction(name: "msa_fragment") else {
                print("❌ [MetalRenderer] Failed to load vertex/fragment functions from library")
                return
            }

            let pipelineDesc = MTLRenderPipelineDescriptor()
            pipelineDesc.vertexFunction = vertexFunc
            pipelineDesc.fragmentFunction = fragmentFunc
            pipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDesc)

            let samplerDesc = MTLSamplerDescriptor()
            samplerDesc.minFilter = .linear
            samplerDesc.magFilter = .linear
            samplerDesc.sAddressMode = .clampToEdge
            samplerDesc.tAddressMode = .clampToEdge
            self.samplerState = device.makeSamplerState(descriptor: samplerDesc)
        } catch {
            print("❌ [MetalRenderer] Pipeline initialization error: \(error)")
        }
    }

    public func render(
        pixelData: Data,
        width: Int,
        height: Int,
        stride: Int,
        format: WaylandShmFormat = .rgba8888,
        to layer: CAMetalLayer
    ) -> Bool {
        guard let pipelineState = self.pipelineState,
              let samplerState = self.samplerState,
              width > 0, height > 0,
              !pixelData.isEmpty else {
            return false
        }

        lock.lock()
        defer { lock.unlock() }

        // 1. Texture management: re-create only when dimensions change
        // Android and standard Linux framebuffers use RGBA byte ordering ([R, G, B, A]).
        let mtlFormat: MTLPixelFormat
        switch format {
        case .argb8888, .xrgb8888:
            mtlFormat = .bgra8Unorm
        case .rgba8888, .rgbx8888, .xbgr8888, .abgr8888:
            mtlFormat = .rgba8Unorm
        }
        if currentTexture == nil || textureWidth != width || textureHeight != height || currentTexture?.pixelFormat != mtlFormat {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: mtlFormat,
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let newTex = device.makeTexture(descriptor: desc) else {
                return false
            }
            self.currentTexture = newTex
            self.textureWidth = width
            self.textureHeight = height
        }

        guard let texture = currentTexture else { return false }

        // 2. Upload raw pixels directly into unified memory texture
        let region = MTLRegionMake2D(0, 0, width, height)
        pixelData.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            texture.replace(region: region, mipmapLevel: 0, withBytes: baseAddress, bytesPerRow: stride)
        }

        // 3. Acquire drawable from CAMetalLayer
        guard let drawable = layer.nextDrawable() else {
            return false
        }

        // 4. Construct render pass descriptor
        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return false
        }

        // 5. Draw fullscreen quad (2 triangles = 6 vertices)
        let quadVertices: [MSAVertex] = [
            MSAVertex(position: SIMD2<Float>(-1.0, -1.0), texCoords: SIMD2<Float>(0.0, 1.0)),
            MSAVertex(position: SIMD2<Float>( 1.0, -1.0), texCoords: SIMD2<Float>(1.0, 1.0)),
            MSAVertex(position: SIMD2<Float>(-1.0,  1.0), texCoords: SIMD2<Float>(0.0, 0.0)),

            MSAVertex(position: SIMD2<Float>(-1.0,  1.0), texCoords: SIMD2<Float>(0.0, 0.0)),
            MSAVertex(position: SIMD2<Float>( 1.0, -1.0), texCoords: SIMD2<Float>(1.0, 1.0)),
            MSAVertex(position: SIMD2<Float>( 1.0,  1.0), texCoords: SIMD2<Float>(1.0, 0.0))
        ]

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(quadVertices, length: MemoryLayout<MSAVertex>.stride * quadVertices.count, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
        return true
    }
}
