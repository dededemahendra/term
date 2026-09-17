/// The Metal shader source, embedded so a build without the Metal
/// toolchain can still compile it at runtime. `scripts/build-shaders.sh`
/// precompiles the same text into `default.metallib`.
public enum Shaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CellInstance { ushort col; ushort row; uint glyph; uint fg; uint bg; uint flags; };
    struct GlyphRect { ushort x; ushort y; ushort w; ushort h; };
    struct Uniforms {
        float4 cursor;
        float4 cursorColor;
        float4 selectionColor;
        float2 cellSize;
        float2 viewport;
        float2 padding;
        float2 atlasSize;
    };
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float2 local;
        float4 fg;
        float4 bg;
        uint flags [[flat]];
    };

    constant uint FLAG_WIDE = 1;
    constant uint FLAG_UNDERLINE = 2;
    constant uint FLAG_STRIKE = 4;
    constant uint FLAG_DIM = 8;
    constant uint FLAG_COLOR = 16;
    constant uint FLAG_SELECTED = 32;
    constant uint FLAG_HIDDEN = 64;
    constant uint FLAG_CURSOR = 128;

    static float4 unpack(uint c) {
        return float4(c & 0xFF, (c >> 8) & 0xFF, (c >> 16) & 0xFF, (c >> 24) & 0xFF) / 255.0;
    }

    vertex VertexOut cell_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                 const device CellInstance* cells [[buffer(0)]],
                                 const device GlyphRect* rects [[buffer(1)]],
                                 constant Uniforms& u [[buffer(2)]]) {
        CellInstance c = cells[iid];
        float2 corner = float2((vid == 1 || vid == 2 || vid == 4) ? 1.0 : 0.0,
                               (vid == 2 || vid == 4 || vid == 5) ? 1.0 : 0.0);
        uint flags = c.flags;
        float w = (flags & FLAG_WIDE) ? 2.0 * u.cellSize.x : u.cellSize.x;
        float2 origin = u.padding + float2(c.col * u.cellSize.x, c.row * u.cellSize.y);
        float2 size = (flags & FLAG_HIDDEN) ? float2(0.0) : float2(w, u.cellSize.y);
        float2 pixel = origin + corner * size;
        float2 ndc = float2(pixel.x / u.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / u.viewport.y * 2.0);
        GlyphRect r = rects[c.glyph];
        float4 fg = unpack(c.fg);
        float4 bg = unpack(c.bg);
        if (flags & FLAG_SELECTED) { bg = u.selectionColor; }
        bool isCursor = u.cursor.w > 0.5 && c.col == uint(u.cursor.x) && c.row == uint(u.cursor.y);
        if (isCursor) {
            flags |= FLAG_CURSOR;
            if (u.cursor.z < 0.5) { fg = bg; bg = u.cursorColor; }
        }
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = (float2(r.x, r.y) + corner * float2(r.w, r.h)) / u.atlasSize;
        out.local = corner * size;
        out.fg = fg;
        out.bg = bg;
        out.flags = flags;
        return out;
    }

    fragment float4 cell_fragment(VertexOut in [[stage_in]],
                                  texture2d<float> atlas [[texture(0)]],
                                  constant Uniforms& u [[buffer(2)]]) {
        constexpr sampler s(mag_filter::nearest, min_filter::nearest);
        float4 t = atlas.sample(s, in.uv);
        float4 glyph = (in.flags & FLAG_COLOR) ? t : float4(in.fg.rgb * t.a, t.a);
        if (in.flags & FLAG_DIM) { glyph *= 0.6; }
        float4 color = in.bg * (1.0 - glyph.a) + glyph;
        float thickness = max(1.0, floor(u.cellSize.y / 14.0));
        float y = in.local.y;
        if ((in.flags & FLAG_UNDERLINE) && y >= u.cellSize.y - thickness) { color = in.fg; }
        float strikeTop = floor((u.cellSize.y - thickness) * 0.5);
        if ((in.flags & FLAG_STRIKE) && y >= strikeTop && y < strikeTop + thickness) { color = in.fg; }
        if (in.flags & FLAG_CURSOR) {
            if (u.cursor.z == 1.0 && y >= u.cellSize.y - thickness * 2.0) { color = u.cursorColor; }
            if (u.cursor.z == 2.0 && in.local.x < thickness * 2.0) { color = u.cursorColor; }
        }
        return float4(color.rgb, 1.0);
    }
    """
}
