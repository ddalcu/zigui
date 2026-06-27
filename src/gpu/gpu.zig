//! SDL_GPU backend: renders a `Canvas` command list on the GPU (Metal on
//! macOS, Vulkan on Linux/Windows, D3D12 once DXIL blobs are added) through
//! SDL3's GPU API — no dependencies beyond the SDL3 the runtime already links.
//!
//! All the interesting decisions are made headlessly in
//! `zigui.gpu_scene.translate` (instances, atlas packing, blur splits); this
//! file is the thin C shell that owns the device/pipelines/textures and
//! replays a translated `Scene`:
//!
//!   * one *unified* instanced pipeline draws every primitive kind (rounded
//!     rects, strokes, gradients, lines, glyph/image quads) in a single draw
//!     call per `Step.draw`, evaluating the same SDFs as `raster.zig` in the
//!     fragment shader, with the clip stack folded into per-instance data;
//!   * `Step.blur` breaks the pass: a horizontal box-blur of the scene into a
//!     scratch texture, then a vertical-blur-plus-tint composite back — the
//!     GPU equivalent of the software `blur_rect`;
//!   * glyph coverage and images live in one shelf-packed RGBA atlas texture,
//!     uploaded incrementally each frame.
//!
//! The frame is rendered into an offscreen scene texture (so blur can sample
//! it) and blitted to the swapchain. Shaders ship as committed SPIR-V blobs
//! (see shaders/compile.sh) plus MSL sources Metal compiles at runtime.
//!
//! Output matches the software rasterizer to within 1 LSB per channel, with
//! one caveat: GPU rasterizers snap vertex edges to a fixed subpixel grid
//! (typically 1/256 px), so a glyph whose origin lands within ~1/512 px of a
//! pixel-center boundary can round to the neighboring column/row where the
//! CPU's exact float compare picked the other side (<0.01% of pixels in the
//! showcase; the glyph itself stays crisp).
//!
//! Like `app.zig`, this file is part of the SDL-linking runtime module and is
//! never compiled into the core library or its test suite.

const std = @import("std");
const zigui = @import("zigui");
const scene_mod = zigui.gpu_scene;

const app = @import("../app.zig");
const c = app.c;

const Allocator = std.mem.Allocator;
const Instance = scene_mod.Instance;

const prim_vert_spv = @embedFile("shaders/prim.vert.spv");
const prim_frag_spv = @embedFile("shaders/prim.frag.spv");
const quad_vert_spv = @embedFile("shaders/quad.vert.spv");
const blur_h_frag_spv = @embedFile("shaders/blur_h.frag.spv");
const blur_v_frag_spv = @embedFile("shaders/blur_v.frag.spv");
const prim_msl = @embedFile("shaders/prim.metal");
const blur_msl = @embedFile("shaders/blur.metal");

/// Uniform block for both blur fragment shaders; layout must match the `Blur`
/// block in blur_h.frag / blur_v.frag / blur.metal (seven float4s, std140).
const BlurUniform = extern struct {
    region: [4]f32,
    texel_br: [4]f32,
    shape: [4]f32,
    tint: [4]f32,
    clip: [4]f32,
    clip_rrect: [4]f32,
    radii: [4]f32,
};

/// Uniform block for quad.vert (blur passes).
const QuadUniform = extern struct {
    viewport: [4]f32,
    rect: [4]f32,
};

pub const Gpu = struct {
    gpa: Allocator,
    device: *c.SDL_GPUDevice,
    /// Null for offscreen (screenshot) rendering.
    window: ?*c.SDL_Window,
    /// The format of every render target (swapchain format when windowed,
    /// RGBA8 offscreen); pipelines are created against it.
    target_format: c.SDL_GPUTextureFormat,
    prim_pipeline: *c.SDL_GPUGraphicsPipeline,
    blur_h_pipeline: *c.SDL_GPUGraphicsPipeline,
    blur_v_pipeline: *c.SDL_GPUGraphicsPipeline,
    sampler: *c.SDL_GPUSampler,

    atlas: scene_mod.Atlas,
    atlas_tex: ?*c.SDL_GPUTexture = null,
    atlas_tex_size: u32 = 0,

    scene_tex: ?*c.SDL_GPUTexture = null,
    scratch_tex: ?*c.SDL_GPUTexture = null,
    tex_w: u32 = 0,
    tex_h: u32 = 0,

    inst_buf: ?*c.SDL_GPUBuffer = null,
    inst_cap: u32 = 0,
    transfer: ?*c.SDL_GPUTransferBuffer = null,
    transfer_cap: u32 = 0,

    /// Create the device and pipelines, claiming `window`'s swapchain when
    /// given (pass null for offscreen rendering). Returns null when no
    /// suitable GPU backend exists — the caller falls back to the software
    /// rasterizer.
    pub fn init(gpa: Allocator, window: ?*c.SDL_Window) ?Gpu {
        const device = c.SDL_CreateGPUDevice(
            c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_MSL,
            false,
            null,
        ) orelse {
            std.log.info("zigui: no GPU backend ({s}); using the software rasterizer", .{c.SDL_GetError()});
            return null;
        };
        var target_format: c.SDL_GPUTextureFormat = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM;
        if (window) |w| {
            if (!c.SDL_ClaimWindowForGPUDevice(device, w)) {
                std.log.info("zigui: GPU swapchain unavailable ({s}); using the software rasterizer", .{c.SDL_GetError()});
                c.SDL_DestroyGPUDevice(device);
                return null;
            }
            target_format = c.SDL_GetGPUSwapchainTextureFormat(device, w);
        }

        var self = Gpu{
            .gpa = gpa,
            .device = device,
            .window = window,
            .target_format = target_format,
            .prim_pipeline = undefined,
            .blur_h_pipeline = undefined,
            .blur_v_pipeline = undefined,
            .sampler = undefined,
            .atlas = scene_mod.Atlas.init(gpa, 1024),
        };
        if (!self.createPipelines()) {
            if (window) |w| c.SDL_ReleaseWindowFromGPUDevice(device, w);
            c.SDL_DestroyGPUDevice(device);
            self.atlas.deinit();
            return null;
        }
        return self;
    }

    pub fn deinit(self: *Gpu) void {
        const d = self.device;
        if (self.inst_buf) |b| c.SDL_ReleaseGPUBuffer(d, b);
        if (self.transfer) |t| c.SDL_ReleaseGPUTransferBuffer(d, t);
        if (self.atlas_tex) |t| c.SDL_ReleaseGPUTexture(d, t);
        if (self.scene_tex) |t| c.SDL_ReleaseGPUTexture(d, t);
        if (self.scratch_tex) |t| c.SDL_ReleaseGPUTexture(d, t);
        c.SDL_ReleaseGPUSampler(d, self.sampler);
        c.SDL_ReleaseGPUGraphicsPipeline(d, self.prim_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(d, self.blur_h_pipeline);
        c.SDL_ReleaseGPUGraphicsPipeline(d, self.blur_v_pipeline);
        if (self.window) |w| c.SDL_ReleaseWindowFromGPUDevice(d, w);
        c.SDL_DestroyGPUDevice(d);
        self.atlas.deinit();
    }

    /// The name of the driver SDL chose ("metal", "vulkan", "direct3d12").
    pub fn driverName(self: *const Gpu) []const u8 {
        const name = c.SDL_GetGPUDeviceDriver(self.device);
        return if (name != null) std.mem.span(name) else "?";
    }

    // -- shaders & pipelines -------------------------------------------------

    const ShaderDesc = struct {
        spv: []const u8,
        msl: []const u8,
        msl_entry: [:0]const u8,
        stage: c.SDL_GPUShaderStage,
        num_samplers: u32 = 0,
        num_uniform_buffers: u32 = 0,
    };

    fn createShader(self: *Gpu, desc: ShaderDesc) ?*c.SDL_GPUShader {
        const formats = c.SDL_GetGPUShaderFormats(self.device);
        var info = c.SDL_GPUShaderCreateInfo{
            .stage = desc.stage,
            .num_samplers = desc.num_samplers,
            .num_storage_textures = 0,
            .num_storage_buffers = 0,
            .num_uniform_buffers = desc.num_uniform_buffers,
            .props = 0,
        };
        if (formats & c.SDL_GPU_SHADERFORMAT_SPIRV != 0) {
            info.format = c.SDL_GPU_SHADERFORMAT_SPIRV;
            info.code = desc.spv.ptr;
            info.code_size = desc.spv.len;
            info.entrypoint = "main";
        } else {
            info.format = c.SDL_GPU_SHADERFORMAT_MSL;
            info.code = desc.msl.ptr;
            info.code_size = desc.msl.len;
            info.entrypoint = desc.msl_entry.ptr;
        }
        return c.SDL_CreateGPUShader(self.device, &info);
    }

    /// Straight-alpha `over`: factors chosen so dst alpha stays saturated
    /// (the scene starts from an opaque clear, like the software framebuffer).
    const over_blend = c.SDL_GPUColorTargetBlendState{
        .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
        .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE,
        .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
        .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
        .color_write_mask = 0,
        .enable_blend = true,
        .enable_color_write_mask = false,
    };

    fn createPipelines(self: *Gpu) bool {
        const d = self.device;
        const prim_vert = self.createShader(.{
            .spv = prim_vert_spv,
            .msl = prim_msl,
            .msl_entry = "prim_vertex",
            .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
            .num_uniform_buffers = 1,
        }) orelse return false;
        defer c.SDL_ReleaseGPUShader(d, prim_vert);
        const prim_frag = self.createShader(.{
            .spv = prim_frag_spv,
            .msl = prim_msl,
            .msl_entry = "prim_fragment",
            .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
            .num_samplers = 1,
        }) orelse return false;
        defer c.SDL_ReleaseGPUShader(d, prim_frag);
        const quad_vert = self.createShader(.{
            .spv = quad_vert_spv,
            .msl = blur_msl,
            .msl_entry = "quad_vertex",
            .stage = c.SDL_GPU_SHADERSTAGE_VERTEX,
            .num_uniform_buffers = 1,
        }) orelse return false;
        defer c.SDL_ReleaseGPUShader(d, quad_vert);
        const blur_h_frag = self.createShader(.{
            .spv = blur_h_frag_spv,
            .msl = blur_msl,
            .msl_entry = "blur_h_fragment",
            .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
            .num_samplers = 1,
            .num_uniform_buffers = 1,
        }) orelse return false;
        defer c.SDL_ReleaseGPUShader(d, blur_h_frag);
        const blur_v_frag = self.createShader(.{
            .spv = blur_v_frag_spv,
            .msl = blur_msl,
            .msl_entry = "blur_v_fragment",
            .stage = c.SDL_GPU_SHADERSTAGE_FRAGMENT,
            .num_samplers = 1,
            .num_uniform_buffers = 1,
        }) orelse return false;
        defer c.SDL_ReleaseGPUShader(d, blur_v_frag);

        // Nine float4 per-instance attributes; one buffer at instance rate.
        var attrs: [9]c.SDL_GPUVertexAttribute = undefined;
        for (&attrs, 0..) |*a, i| {
            a.* = .{
                .location = @intCast(i),
                .buffer_slot = 0,
                .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
                .offset = @intCast(i * 16),
            };
        }
        std.debug.assert(@sizeOf(Instance) == 9 * 16);
        const vbuf_desc = c.SDL_GPUVertexBufferDescription{
            .slot = 0,
            .pitch = @sizeOf(Instance),
            .input_rate = c.SDL_GPU_VERTEXINPUTRATE_INSTANCE,
            .instance_step_rate = 0,
        };
        const color_target = c.SDL_GPUColorTargetDescription{
            .format = self.target_format,
            .blend_state = over_blend,
        };

        var info = c.SDL_GPUGraphicsPipelineCreateInfo{
            .vertex_shader = prim_vert,
            .fragment_shader = prim_frag,
            .vertex_input_state = .{
                .vertex_buffer_descriptions = &vbuf_desc,
                .num_vertex_buffers = 1,
                .vertex_attributes = &attrs,
                .num_vertex_attributes = attrs.len,
            },
            .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLESTRIP,
            .rasterizer_state = .{},
            .multisample_state = .{},
            .depth_stencil_state = .{},
            .target_info = .{
                .color_target_descriptions = &color_target,
                .num_color_targets = 1,
            },
            .props = 0,
        };
        self.prim_pipeline = c.SDL_CreateGPUGraphicsPipeline(d, &info) orelse return false;

        // Blur pipelines share the bare quad vertex shader and have no vertex
        // buffer. The horizontal pass overwrites scratch (no blending); the
        // vertical pass composites into the scene with the same `over`.
        info.vertex_shader = quad_vert;
        info.vertex_input_state = .{};
        info.fragment_shader = blur_h_frag;
        var no_blend_target = color_target;
        no_blend_target.blend_state = .{};
        info.target_info.color_target_descriptions = &no_blend_target;
        self.blur_h_pipeline = c.SDL_CreateGPUGraphicsPipeline(d, &info) orelse {
            c.SDL_ReleaseGPUGraphicsPipeline(d, self.prim_pipeline);
            return false;
        };
        info.fragment_shader = blur_v_frag;
        info.target_info.color_target_descriptions = &color_target;
        self.blur_v_pipeline = c.SDL_CreateGPUGraphicsPipeline(d, &info) orelse {
            c.SDL_ReleaseGPUGraphicsPipeline(d, self.prim_pipeline);
            c.SDL_ReleaseGPUGraphicsPipeline(d, self.blur_h_pipeline);
            return false;
        };

        // Nearest sampling matches the software rasterizer's glyph/image path
        // (and keeps atlas entries from bleeding).
        self.sampler = c.SDL_CreateGPUSampler(self.device, &.{
            .min_filter = c.SDL_GPU_FILTER_NEAREST,
            .mag_filter = c.SDL_GPU_FILTER_NEAREST,
            .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
            .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        }) orelse {
            c.SDL_ReleaseGPUGraphicsPipeline(d, self.prim_pipeline);
            c.SDL_ReleaseGPUGraphicsPipeline(d, self.blur_h_pipeline);
            c.SDL_ReleaseGPUGraphicsPipeline(d, self.blur_v_pipeline);
            return false;
        };
        return true;
    }

    // -- per-frame resources -------------------------------------------------

    fn makeTexture(self: *Gpu, w: u32, h: u32, format: c.SDL_GPUTextureFormat) ?*c.SDL_GPUTexture {
        return c.SDL_CreateGPUTexture(self.device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = format,
            .usage = c.SDL_GPU_TEXTUREUSAGE_COLOR_TARGET | c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = w,
            .height = h,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        });
    }

    fn ensureFrameTextures(self: *Gpu, w: u32, h: u32) bool {
        if (self.scene_tex != null and self.tex_w == w and self.tex_h == h) return true;
        if (self.scene_tex) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        if (self.scratch_tex) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        self.scene_tex = self.makeTexture(w, h, self.target_format);
        self.scratch_tex = self.makeTexture(w, h, self.target_format);
        self.tex_w = w;
        self.tex_h = h;
        return self.scene_tex != null and self.scratch_tex != null;
    }

    fn ensureAtlasTexture(self: *Gpu) bool {
        if (self.atlas_tex != null and self.atlas_tex_size == self.atlas.size) return true;
        if (self.atlas_tex) |t| c.SDL_ReleaseGPUTexture(self.device, t);
        self.atlas_tex = c.SDL_CreateGPUTexture(self.device, &.{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
            .width = self.atlas.size,
            .height = self.atlas.size,
            .layer_count_or_depth = 1,
            .num_levels = 1,
        });
        self.atlas_tex_size = self.atlas.size;
        return self.atlas_tex != null;
    }

    /// Translate with atlas-full recovery: grow (or, at max size, evict) and
    /// retry — a reset invalidates the entries staged so far, so the whole
    /// command list is re-translated against the fresh atlas.
    fn translateScene(
        self: *Gpu,
        arena: Allocator,
        commands: []const zigui.DrawCommand,
        w: f32,
        h: f32,
    ) ?scene_mod.Scene {
        var attempts: u2 = 0;
        while (attempts < 3) : (attempts += 1) {
            return scene_mod.translate(arena, commands, &self.atlas, w, h) catch |err| switch (err) {
                error.AtlasFull => {
                    if (!self.atlas.grow()) self.atlas.reset();
                    continue;
                },
                error.OutOfMemory => return null,
            };
        }
        return null;
    }

    /// Stage instance data and pending atlas uploads through the (grown as
    /// needed) transfer buffer, recording the copy commands on `cmdbuf`.
    fn upload(self: *Gpu, cmdbuf: *c.SDL_GPUCommandBuffer, scene: scene_mod.Scene) bool {
        const pending = self.atlas.pendingUploads();
        const inst_bytes: u32 = @intCast(scene.instances.len * @sizeOf(Instance));
        var total: u32 = inst_bytes;
        for (pending) |p| total += @intCast(p.pixels.len);
        if (total == 0) return true;

        if (self.transfer == null or self.transfer_cap < total) {
            if (self.transfer) |t| c.SDL_ReleaseGPUTransferBuffer(self.device, t);
            self.transfer_cap = @max(total, @max(self.transfer_cap * 2, 1 << 20));
            self.transfer = c.SDL_CreateGPUTransferBuffer(self.device, &.{
                .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
                .size = self.transfer_cap,
            });
            if (self.transfer == null) return false;
        }
        if (inst_bytes > 0 and (self.inst_buf == null or self.inst_cap < inst_bytes)) {
            if (self.inst_buf) |b| c.SDL_ReleaseGPUBuffer(self.device, b);
            self.inst_cap = @max(inst_bytes, @max(self.inst_cap * 2, 1 << 19));
            self.inst_buf = c.SDL_CreateGPUBuffer(self.device, &.{
                .usage = c.SDL_GPU_BUFFERUSAGE_VERTEX,
                .size = self.inst_cap,
            });
            if (self.inst_buf == null) return false;
        }

        const mapped: [*]u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.device, self.transfer, true) orelse return false);
        if (inst_bytes > 0) @memcpy(mapped[0..inst_bytes], std.mem.sliceAsBytes(scene.instances));
        var off: u32 = inst_bytes;
        for (pending) |p| {
            @memcpy(mapped[off..][0..p.pixels.len], p.pixels);
            off += @intCast(p.pixels.len);
        }
        c.SDL_UnmapGPUTransferBuffer(self.device, self.transfer);

        const copy = c.SDL_BeginGPUCopyPass(cmdbuf) orelse return false;
        if (inst_bytes > 0) {
            c.SDL_UploadToGPUBuffer(
                copy,
                &.{ .transfer_buffer = self.transfer, .offset = 0 },
                &.{ .buffer = self.inst_buf, .offset = 0, .size = inst_bytes },
                true,
            );
        }
        off = inst_bytes;
        for (pending) |p| {
            c.SDL_UploadToGPUTexture(
                copy,
                &.{ .transfer_buffer = self.transfer, .offset = off, .pixels_per_row = p.w, .rows_per_layer = p.h },
                &.{ .texture = self.atlas_tex, .x = p.x, .y = p.y, .w = p.w, .h = p.h, .d = 1 },
                false, // preserve the rest of the atlas
            );
            off += @intCast(p.pixels.len);
        }
        c.SDL_EndGPUCopyPass(copy);
        self.atlas.clearPending();
        return true;
    }

    // -- frame encoding ------------------------------------------------------

    const Encoder = struct {
        gpu: *Gpu,
        cmdbuf: *c.SDL_GPUCommandBuffer,
        w: u32,
        h: u32,
        clear: zigui.Color,
        pass: ?*c.SDL_GPURenderPass = null,
        cleared: bool = false,

        fn sceneTarget(self: *Encoder, load: c.SDL_GPULoadOp) c.SDL_GPUColorTargetInfo {
            return .{
                .texture = self.gpu.scene_tex,
                .clear_color = .{ .r = self.clear.r, .g = self.clear.g, .b = self.clear.b, .a = self.clear.a },
                .load_op = load,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .cycle = load == c.SDL_GPU_LOADOP_CLEAR,
            };
        }

        /// Open (or reuse) a render pass on the scene texture with the prim
        /// pipeline fully bound. The first pass of the frame clears.
        fn beginPrimPass(self: *Encoder) ?*c.SDL_GPURenderPass {
            if (self.pass) |p| return p;
            const load: c.SDL_GPULoadOp = if (self.cleared) c.SDL_GPU_LOADOP_LOAD else c.SDL_GPU_LOADOP_CLEAR;
            const target = self.sceneTarget(load);
            const pass = c.SDL_BeginGPURenderPass(self.cmdbuf, &target, 1, null) orelse return null;
            self.cleared = true;
            self.pass = pass;
            c.SDL_BindGPUGraphicsPipeline(pass, self.gpu.prim_pipeline);
            c.SDL_BindGPUVertexBuffers(pass, 0, &.{ .buffer = self.gpu.inst_buf, .offset = 0 }, 1);
            c.SDL_BindGPUFragmentSamplers(pass, 0, &.{ .texture = self.gpu.atlas_tex, .sampler = self.gpu.sampler }, 1);
            const viewport = [4]f32{ @floatFromInt(self.w), @floatFromInt(self.h), 0, 0 };
            c.SDL_PushGPUVertexUniformData(self.cmdbuf, 0, &viewport, @sizeOf(@TypeOf(viewport)));
            return pass;
        }

        fn endPass(self: *Encoder) void {
            if (self.pass) |p| c.SDL_EndGPURenderPass(p);
            self.pass = null;
        }

        /// Make sure the scene texture has defined contents (a frame whose
        /// first command is a blur must not sample garbage).
        fn ensureCleared(self: *Encoder) void {
            if (self.cleared) return;
            const target = self.sceneTarget(c.SDL_GPU_LOADOP_CLEAR);
            if (c.SDL_BeginGPURenderPass(self.cmdbuf, &target, 1, null)) |p| {
                c.SDL_EndGPURenderPass(p);
                self.cleared = true;
            }
        }

        fn drawStep(self: *Encoder, first: u32, count: u32) void {
            const pass = self.beginPrimPass() orelse return;
            c.SDL_DrawGPUPrimitives(pass, 4, count, 0, first);
        }

        fn blurStep(self: *Encoder, bl: anytype) void {
            self.endPass();
            self.ensureCleared();
            const fw: f32 = @floatFromInt(self.w);
            const fh: f32 = @floatFromInt(self.h);
            // Snapshot region: the blur rect's pixel bounds expanded by the
            // box radius, clamped to the framebuffer (raster.zig's `ex0..ey1`).
            const br = @max(1.0, @round(bl.sigma));
            const x0 = @max(0, @floor(bl.rect[0]) - br);
            const y0 = @max(0, @floor(bl.rect[1]) - br);
            const x1 = @min(fw, @ceil(bl.rect[0] + bl.rect[2]) + br);
            const y1 = @min(fh, @ceil(bl.rect[1] + bl.rect[3]) + br);
            if (x1 <= x0 or y1 <= y0) return;
            var uni = BlurUniform{
                .region = .{ x0, y0, x1, y1 },
                .texel_br = .{ 1.0 / fw, 1.0 / fh, br, 0 },
                .shape = bl.rect,
                .tint = bl.tint,
                .clip = bl.clip,
                .clip_rrect = bl.clip_rrect,
                .radii = .{ bl.radius, bl.clip_radius, 0, 0 },
            };
            var quad = QuadUniform{
                .viewport = .{ fw, fh, 0, 0 },
                .rect = .{ x0, y0, x1 - x0, y1 - y0 },
            };

            // Horizontal pass: scene -> scratch over the whole snapshot region.
            const scratch_target = c.SDL_GPUColorTargetInfo{
                .texture = self.gpu.scratch_tex,
                .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
                .store_op = c.SDL_GPU_STOREOP_STORE,
                .cycle = true,
            };
            const hpass = c.SDL_BeginGPURenderPass(self.cmdbuf, &scratch_target, 1, null) orelse return;
            c.SDL_BindGPUGraphicsPipeline(hpass, self.gpu.blur_h_pipeline);
            c.SDL_BindGPUFragmentSamplers(hpass, 0, &.{ .texture = self.gpu.scene_tex, .sampler = self.gpu.sampler }, 1);
            c.SDL_PushGPUVertexUniformData(self.cmdbuf, 0, &quad, @sizeOf(QuadUniform));
            c.SDL_PushGPUFragmentUniformData(self.cmdbuf, 0, &uni, @sizeOf(BlurUniform));
            c.SDL_DrawGPUPrimitives(hpass, 4, 1, 0, 0);
            c.SDL_EndGPURenderPass(hpass);

            // Vertical pass + tint composite back into the scene, masked by
            // the (rounded) blur rect; pad 1px for the SDF's AA fringe.
            const vtarget = self.sceneTarget(c.SDL_GPU_LOADOP_LOAD);
            const vpass = c.SDL_BeginGPURenderPass(self.cmdbuf, &vtarget, 1, null) orelse return;
            c.SDL_BindGPUGraphicsPipeline(vpass, self.gpu.blur_v_pipeline);
            c.SDL_BindGPUFragmentSamplers(vpass, 0, &.{ .texture = self.gpu.scratch_tex, .sampler = self.gpu.sampler }, 1);
            quad.rect = .{ bl.rect[0] - 1, bl.rect[1] - 1, bl.rect[2] + 2, bl.rect[3] + 2 };
            c.SDL_PushGPUVertexUniformData(self.cmdbuf, 0, &quad, @sizeOf(QuadUniform));
            c.SDL_PushGPUFragmentUniformData(self.cmdbuf, 0, &uni, @sizeOf(BlurUniform));
            c.SDL_DrawGPUPrimitives(vpass, 4, 1, 0, 0);
            c.SDL_EndGPURenderPass(vpass);
        }
    };

    /// Encode a translated scene into `cmdbuf`, rendering into the scene
    /// texture (cleared to `clear` on first use).
    fn encode(
        self: *Gpu,
        cmdbuf: *c.SDL_GPUCommandBuffer,
        scene: scene_mod.Scene,
        clear: zigui.Color,
        w: u32,
        h: u32,
    ) void {
        var enc = Encoder{ .gpu = self, .cmdbuf = cmdbuf, .w = w, .h = h, .clear = clear };
        for (scene.steps) |step| {
            switch (step) {
                .draw => |dr| enc.drawStep(dr.first, dr.count),
                .blur => |bl| enc.blurStep(bl),
            }
        }
        enc.endPass();
        enc.ensureCleared(); // empty command list still presents the bg color
    }

    /// Render one frame and present it to the window swapchain. Returns false
    /// when nothing was presented (minimized swapchain, lost device, OOM) —
    /// the caller just skips the frame.
    pub fn frame(
        self: *Gpu,
        arena: Allocator,
        commands: []const zigui.DrawCommand,
        clear: zigui.Color,
        oversample: f32,
    ) bool {
        const window = self.window orelse return false;
        const cmdbuf = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return false;
        var swap_tex: ?*c.SDL_GPUTexture = null;
        var sw: u32 = 0;
        var sh: u32 = 0;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmdbuf, window, &swap_tex, &sw, &sh) or swap_tex == null) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmdbuf);
            return false;
        }
        // Supersampling: render the scene into an oversampled texture (`dw`×`dh`)
        // matching the already-scaled command list, then downscale it onto the
        // swapchain in the final blit (LINEAR). `oversample` == 1 keeps the old
        // 1:1 path exactly (NEAREST blit).
        const ss = @max(1, oversample);
        const dw: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(sw)) * ss));
        const dh: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(sh)) * ss));
        const scene = self.translateScene(arena, commands, @floatFromInt(dw), @floatFromInt(dh)) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmdbuf);
            return false;
        };
        if (!self.ensureAtlasTexture() or !self.ensureFrameTextures(dw, dh) or !self.upload(cmdbuf, scene)) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmdbuf);
            return false;
        }

        self.encode(cmdbuf, scene, clear, dw, dh);

        c.SDL_BlitGPUTexture(cmdbuf, &.{
            .source = .{ .texture = self.scene_tex, .w = dw, .h = dh },
            .destination = .{ .texture = swap_tex, .w = sw, .h = sh },
            .load_op = c.SDL_GPU_LOADOP_DONT_CARE,
            .filter = if (dw != sw) c.SDL_GPU_FILTER_LINEAR else c.SDL_GPU_FILTER_NEAREST,
        });
        return c.SDL_SubmitGPUCommandBuffer(cmdbuf);
    }

    /// Render `commands` offscreen at `w`x`h` and read the pixels back as
    /// tightly-packed RGBA8 (gpa-owned). Headless verification path — lets
    /// `showcase --screenshot --gpu` exercise the real GPU pipeline without a
    /// window. Returns null on any GPU failure.
    pub fn renderToRgba(
        self: *Gpu,
        arena: Allocator,
        commands: []const zigui.DrawCommand,
        clear: zigui.Color,
        w: u32,
        h: u32,
    ) ?[]u8 {
        self.tex_w = 0; // force texture (re)creation at the requested size
        if (!self.ensureFrameTextures(w, h)) return null;
        const scene = self.translateScene(arena, commands, @floatFromInt(w), @floatFromInt(h)) orelse return null;
        if (!self.ensureAtlasTexture()) return null;

        const cmdbuf = c.SDL_AcquireGPUCommandBuffer(self.device) orelse return null;
        if (!self.upload(cmdbuf, scene)) {
            _ = c.SDL_SubmitGPUCommandBuffer(cmdbuf);
            return null;
        }
        self.encode(cmdbuf, scene, clear, w, h);

        const byte_count: u32 = w * h * 4;
        const download = c.SDL_CreateGPUTransferBuffer(self.device, &.{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_DOWNLOAD,
            .size = byte_count,
        }) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmdbuf);
            return null;
        };
        defer c.SDL_ReleaseGPUTransferBuffer(self.device, download);
        const copy = c.SDL_BeginGPUCopyPass(cmdbuf) orelse {
            _ = c.SDL_SubmitGPUCommandBuffer(cmdbuf);
            return null;
        };
        c.SDL_DownloadFromGPUTexture(
            copy,
            &.{ .texture = self.scene_tex, .w = w, .h = h, .d = 1 },
            &.{ .transfer_buffer = download, .offset = 0, .pixels_per_row = w, .rows_per_layer = h },
        );
        c.SDL_EndGPUCopyPass(copy);

        const fence = c.SDL_SubmitGPUCommandBufferAndAcquireFence(cmdbuf) orelse return null;
        defer c.SDL_ReleaseGPUFence(self.device, fence);
        if (!c.SDL_WaitForGPUFences(self.device, true, &fence, 1)) return null;

        const mapped: [*]const u8 = @ptrCast(c.SDL_MapGPUTransferBuffer(self.device, download, false) orelse return null);
        defer c.SDL_UnmapGPUTransferBuffer(self.device, download);
        const out = self.gpa.alloc(u8, byte_count) catch return null;
        @memcpy(out, mapped[0..byte_count]);
        return out;
    }
};
