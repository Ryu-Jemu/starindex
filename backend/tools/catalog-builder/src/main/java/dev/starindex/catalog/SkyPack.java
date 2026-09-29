package dev.starindex.catalog;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * skypack v1 binary format (little-endian). See docs/skypack-format.md.
 *
 * <pre>
 * header 32 B : "SKYP" | u16 version | u16 flags | f32 epoch | f32 magLimit |
 *               u32 starCount | u32 constellationCount | u32 segmentCount | u32 stringCount
 * star    24 B: f32 x, y, z (J2000 unit vector at epoch) | i16 mag×100 | u8 bvIndex | u8 flags |
 *               u16 hr | u16 reserved | i32 nameIdx (−1 = none)
 * const   24 B: 4 B IAU abbr (ASCII, NUL-padded) | i32 nameKoIdx | i32 nameLatinIdx | f32 anchor x, y, z
 * segment  8 B: u16 constellationIdx | u16 reserved | u16 starA | u16 starB
 * string     : u16 byteLength | UTF-8 bytes
 * </pre>
 */
final class SkyPack {
    static final int VERSION = 1;
    static final int FLAG_LINE_ONLY = 1;   // point exists only as a stick-figure vertex (not drawn as a star)
    static final int FLAG_HAS_NAME = 2;

    record Star(float x, float y, float z, short mag100, int bvIndex, int flags, int hr, int nameIdx) {}
    record Constellation(String abbr, int nameKoIdx, int nameLatinIdx, float ax, float ay, float az) {}
    record Segment(int constellation, int a, int b) {}
    record Pack(float epoch, float magLimit, List<Star> stars, List<Constellation> constellations,
                List<Segment> segments, List<String> strings) {}

    static byte[] encode(Pack p) {
        int size = 32 + 24 * p.stars().size() + 24 * p.constellations().size() + 8 * p.segments().size();
        List<byte[]> encoded = new ArrayList<>();
        for (String s : p.strings()) {
            byte[] b = s.getBytes(StandardCharsets.UTF_8);
            if (b.length > 0xFFFF) throw new IllegalArgumentException("string too long");
            encoded.add(b);
            size += 2 + b.length;
        }
        ByteBuffer buf = ByteBuffer.allocate(size).order(ByteOrder.LITTLE_ENDIAN);
        buf.put("SKYP".getBytes(StandardCharsets.US_ASCII));
        buf.putShort((short) VERSION).putShort((short) 0);
        buf.putFloat(p.epoch()).putFloat(p.magLimit());
        buf.putInt(p.stars().size()).putInt(p.constellations().size()).putInt(p.segments().size()).putInt(encoded.size());
        for (Star s : p.stars()) {
            buf.putFloat(s.x()).putFloat(s.y()).putFloat(s.z());
            buf.putShort(s.mag100()).put((byte) s.bvIndex()).put((byte) s.flags());
            buf.putShort((short) s.hr()).putShort((short) 0).putInt(s.nameIdx());
        }
        for (Constellation c : p.constellations()) {
            byte[] abbr = new byte[4];
            byte[] src = c.abbr().getBytes(StandardCharsets.US_ASCII);
            System.arraycopy(src, 0, abbr, 0, Math.min(4, src.length));
            buf.put(abbr).putInt(c.nameKoIdx()).putInt(c.nameLatinIdx());
            buf.putFloat(c.ax()).putFloat(c.ay()).putFloat(c.az());
        }
        for (Segment s : p.segments()) {
            buf.putShort((short) s.constellation()).putShort((short) 0).putShort((short) s.a()).putShort((short) s.b());
        }
        for (byte[] b : encoded) buf.putShort((short) b.length).put(b);
        return buf.array();
    }

    static Pack decode(byte[] bytes) {
        ByteBuffer buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        byte[] magic = new byte[4];
        buf.get(magic);
        if (!"SKYP".equals(new String(magic, StandardCharsets.US_ASCII))) throw new IllegalArgumentException("bad magic");
        int version = Short.toUnsignedInt(buf.getShort());
        if (version != VERSION) throw new IllegalArgumentException("unsupported version " + version);
        buf.getShort();
        float epoch = buf.getFloat(), magLimit = buf.getFloat();
        int nStars = buf.getInt(), nConst = buf.getInt(), nSeg = buf.getInt(), nStr = buf.getInt();
        List<Star> stars = new ArrayList<>(nStars);
        for (int i = 0; i < nStars; i++) {
            float x = buf.getFloat(), y = buf.getFloat(), z = buf.getFloat();
            short mag = buf.getShort();
            int bv = Byte.toUnsignedInt(buf.get()), flags = Byte.toUnsignedInt(buf.get());
            int hr = Short.toUnsignedInt(buf.getShort());
            buf.getShort();
            stars.add(new Star(x, y, z, mag, bv, flags, hr, buf.getInt()));
        }
        List<Constellation> consts = new ArrayList<>(nConst);
        for (int i = 0; i < nConst; i++) {
            byte[] a = new byte[4];
            buf.get(a);
            String abbr = new String(a, StandardCharsets.US_ASCII).replace("\0", "");
            consts.add(new Constellation(abbr, buf.getInt(), buf.getInt(), buf.getFloat(), buf.getFloat(), buf.getFloat()));
        }
        List<Segment> segs = new ArrayList<>(nSeg);
        for (int i = 0; i < nSeg; i++) {
            int c = Short.toUnsignedInt(buf.getShort());
            buf.getShort();
            segs.add(new Segment(c, Short.toUnsignedInt(buf.getShort()), Short.toUnsignedInt(buf.getShort())));
        }
        List<String> strings = new ArrayList<>(nStr);
        for (int i = 0; i < nStr; i++) {
            byte[] b = new byte[Short.toUnsignedInt(buf.getShort())];
            buf.get(b);
            strings.add(new String(b, StandardCharsets.UTF_8));
        }
        if (buf.hasRemaining()) throw new IllegalArgumentException("trailing bytes");
        return new Pack(epoch, magLimit, stars, consts, segs, strings);
    }

    static Pack read(Path p) throws IOException { return decode(Files.readAllBytes(p)); }
}
