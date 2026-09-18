// The robot's face, drawn on the Mac, with no robot.
//
// `tools/screenshot.py` shows what the robot is doing right now, which is the
// truth but needs a robot that is awake, reachable, and in the state you want
// to look at. Some states are hard to reach on purpose (the trouble face) or
// last 175 ms (the eyes mid-close). This runs the SAME firmware drawing code
// against a canvas here and writes a PNG, so any expression or any moment of
// an animation can be looked at in a second.
//
//   c++ -std=c++17 -include initializer_list -I companion/stubs \
//       companion/render_face.cpp -o /tmp/render_face
//   /tmp/render_face --expression trouble --out /tmp/trouble.png
//   /tmp/render_face --closing 0.9 --out /tmp/shut.png
//   /tmp/render_face --sheet /tmp/faces          # every expression
//
// PNG is written by hand (stored deflate blocks) so this needs no libraries
// beyond the standard one -- a renderer that cannot be built is no renderer.

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

uint32_t stanbot_test_now_ms = 0;

static constexpr int kWidth = 320;
static constexpr int kHeight = 240;

/// The six primitives the firmware's face code uses, and nothing else.
struct Canvas {
    std::vector<uint8_t> rgb = std::vector<uint8_t>(kWidth * kHeight * 3, 0);

    static void unpack(uint16_t colour, uint8_t& r, uint8_t& g, uint8_t& b) {
        r = static_cast<uint8_t>(((colour >> 11) & 0x1F) * 255 / 31);
        g = static_cast<uint8_t>(((colour >> 5) & 0x3F) * 255 / 63);
        b = static_cast<uint8_t>((colour & 0x1F) * 255 / 31);
    }

    void plot(int x, int y, uint16_t colour) {
        if (x < 0 || y < 0 || x >= kWidth || y >= kHeight) return;   // the panel clips too
        uint8_t r, g, b;
        unpack(colour, r, g, b);
        uint8_t* p = &rgb[(y * kWidth + x) * 3];
        p[0] = r; p[1] = g; p[2] = b;
    }

    void fillScreen(uint16_t colour) {
        for (int y = 0; y < kHeight; ++y)
            for (int x = 0; x < kWidth; ++x) plot(x, y, colour);
    }

    void fillRect(int x, int y, int w, int h, uint16_t colour) {
        for (int j = y; j < y + h; ++j)
            for (int i = x; i < x + w; ++i) plot(i, j, colour);
    }

    void fillCircle(int cx, int cy, int r, uint16_t colour) {
        for (int j = -r; j <= r; ++j)
            for (int i = -r; i <= r; ++i)
                if (i * i + j * j <= r * r) plot(cx + i, cy + j, colour);
    }

    void fillRoundRect(int x, int y, int w, int h, int r, uint16_t colour) {
        if (r * 2 > w) r = w / 2;
        if (r * 2 > h) r = h / 2;
        fillRect(x + r, y, w - 2 * r, h, colour);
        fillRect(x, y + r, r, h - 2 * r, colour);
        fillRect(x + w - r, y + r, r, h - 2 * r, colour);
        fillCircle(x + r, y + r, r, colour);
        fillCircle(x + w - r - 1, y + r, r, colour);
        fillCircle(x + r, y + h - r - 1, r, colour);
        fillCircle(x + w - r - 1, y + h - r - 1, r, colour);
    }

    void fillTriangle(int x0, int y0, int x1, int y1, int x2, int y2, uint16_t colour) {
        const int minX = std::min({x0, x1, x2}), maxX = std::max({x0, x1, x2});
        const int minY = std::min({y0, y1, y2}), maxY = std::max({y0, y1, y2});
        auto edge = [](int ax, int ay, int bx, int by, int px, int py) {
            return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
        };
        for (int y = minY; y <= maxY; ++y) {
            for (int x = minX; x <= maxX; ++x) {
                const int a = edge(x0, y0, x1, y1, x, y);
                const int b = edge(x1, y1, x2, y2, x, y);
                const int c = edge(x2, y2, x0, y0, x, y);
                if ((a >= 0 && b >= 0 && c >= 0) || (a <= 0 && b <= 0 && c <= 0)) plot(x, y, colour);
            }
        }
    }

    /// M5GFX sweeps clockwise from 3 o'clock, with y increasing downward.
    void fillArc(int cx, int cy, int r0, int r1, int a0, int a1, uint16_t colour) {
        while (a1 < a0) a1 += 360;
        for (int y = cy - r1; y <= cy + r1; ++y) {
            for (int x = cx - r1; x <= cx + r1; ++x) {
                const double dx = x - cx, dy = y - cy;
                const double distance = std::sqrt(dx * dx + dy * dy);
                if (distance < r0 || distance > r1) continue;
                double angle = std::atan2(dy, dx) * 180.0 / M_PI;
                if (angle < 0) angle += 360;
                if (angle < a0) angle += 360;
                if (angle <= a1) plot(x, y, colour);
            }
        }
    }

    /// The firmware passes half the line width, as drawTrouble's comment says.
    void drawWideLine(int x0, int y0, int x1, int y1, int halfWidth, uint16_t colour) {
        const double dx = x1 - x0, dy = y1 - y0;
        const double length = std::sqrt(dx * dx + dy * dy);
        if (length < 1) { fillCircle(x0, y0, halfWidth, colour); return; }
        const int steps = static_cast<int>(length * 2);
        for (int i = 0; i <= steps; ++i) {
            const double t = static_cast<double>(i) / steps;
            fillCircle(static_cast<int>(x0 + dx * t), static_cast<int>(y0 + dy * t), halfWidth, colour);
        }
    }
};

#include "../firmware/lib/StanbotEyes/src/StanbotEyes.h"

// ---- PNG, written by hand so this has no dependencies -----------------------

static uint32_t crcTable[256];
static void buildCrc() {
    for (uint32_t n = 0; n < 256; ++n) {
        uint32_t c = n;
        for (int k = 0; k < 8; ++k) c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        crcTable[n] = c;
    }
}
static uint32_t crc(const uint8_t* data, size_t length, uint32_t start = 0xFFFFFFFFu) {
    uint32_t c = start;
    for (size_t i = 0; i < length; ++i) c = crcTable[(c ^ data[i]) & 0xFF] ^ (c >> 8);
    return c;
}
static void be32(std::vector<uint8_t>& out, uint32_t value) {
    out.push_back(value >> 24); out.push_back(value >> 16);
    out.push_back(value >> 8);  out.push_back(value);
}
static void chunk(std::vector<uint8_t>& png, const char* type, const std::vector<uint8_t>& data) {
    be32(png, static_cast<uint32_t>(data.size()));
    std::vector<uint8_t> body(type, type + 4);
    body.insert(body.end(), data.begin(), data.end());
    png.insert(png.end(), body.begin(), body.end());
    be32(png, crc(body.data(), body.size()) ^ 0xFFFFFFFFu);
}

static bool writePng(const std::string& path, const std::vector<uint8_t>& rgb) {
    buildCrc();
    std::vector<uint8_t> raw;
    for (int y = 0; y < kHeight; ++y) {
        raw.push_back(0);   // filter: none
        raw.insert(raw.end(), rgb.begin() + y * kWidth * 3, rgb.begin() + (y + 1) * kWidth * 3);
    }
    // zlib with stored (uncompressed) deflate blocks: larger, but no library.
    std::vector<uint8_t> z{0x78, 0x01};
    size_t offset = 0;
    while (offset < raw.size()) {
        const uint16_t block = static_cast<uint16_t>(std::min<size_t>(65535, raw.size() - offset));
        const bool last = offset + block >= raw.size();
        z.push_back(last ? 1 : 0);
        z.push_back(block & 0xFF); z.push_back(block >> 8);
        z.push_back(~block & 0xFF); z.push_back((~block >> 8) & 0xFF);
        z.insert(z.end(), raw.begin() + offset, raw.begin() + offset + block);
        offset += block;
    }
    uint32_t a = 1, b = 0;
    for (uint8_t byte : raw) { a = (a + byte) % 65521; b = (b + a) % 65521; }
    be32(z, (b << 16) | a);

    std::vector<uint8_t> png{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A};
    std::vector<uint8_t> ihdr;
    be32(ihdr, kWidth); be32(ihdr, kHeight);
    ihdr.push_back(8); ihdr.push_back(2); ihdr.push_back(0); ihdr.push_back(0); ihdr.push_back(0);
    chunk(png, "IHDR", ihdr);
    chunk(png, "IDAT", z);
    chunk(png, "IEND", {});

    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) return false;
    const bool ok = std::fwrite(png.data(), 1, png.size(), f) == png.size();
    std::fclose(f);
    return ok;
}

// ---- driving the face -------------------------------------------------------

struct Named { const char* name; StanbotEmotion emotion; };
static const Named kEmotions[] = {
    {"normal", StanbotEmotion::Normal},       {"angry", StanbotEmotion::Angry},
    {"glee", StanbotEmotion::Glee},           {"happy", StanbotEmotion::Happy},
    {"sad", StanbotEmotion::Sad},             {"worried", StanbotEmotion::Worried},
    {"focused", StanbotEmotion::Focused},     {"annoyed", StanbotEmotion::Annoyed},
    {"surprised", StanbotEmotion::Surprised}, {"skeptic", StanbotEmotion::Skeptic},
    {"frustrated", StanbotEmotion::Frustrated}, {"unimpressed", StanbotEmotion::Unimpressed},
    {"sleepy", StanbotEmotion::Sleepy},       {"suspicious", StanbotEmotion::Suspicious},
    {"squint", StanbotEmotion::Squint},       {"furious", StanbotEmotion::Furious},
    {"scared", StanbotEmotion::Scared},       {"awe", StanbotEmotion::Awe},
    {"trouble", StanbotEmotion::Trouble},
};

/// Render one face. `closing` 0 is wide awake, 1 fully shut.
static Canvas render(StanbotEmotion emotion, double closing, bool settle) {
    StanbotEyes eyes;
    eyes.begin(0);
    eyes.setEmotion(emotion);
    Canvas canvas;
    uint32_t now = 0;
    // The pose springs toward its target by 10% a frame, so a single frame
    // shows the PREVIOUS expression sliding into this one. Settling first is
    // what makes a rendered sheet comparable to a robot that has been sitting
    // in that expression.
    if (settle) {
        for (int frame = 0; frame < 120; ++frame) { now += 34; eyes.update(canvas, now); }
    }
    if (closing > 0) {
        eyes.beginSleep(now);
        const uint32_t span = static_cast<uint32_t>(stanbot::SleepCurtain::kCloseMs * closing);
        const uint32_t target = now + span;
        while (now < target) { now += 17; eyes.update(canvas, now); }
        // One more frame exactly at the asked-for moment.
        eyes.update(canvas, target + 34);
    } else {
        now += 34;
        eyes.update(canvas, now);
    }
    return canvas;
}

int main(int argc, char** argv) {
    std::string out = "face.png", expression = "normal", sheet;
    double closing = 0;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        const bool more = i + 1 < argc;
        if (arg == "--out" && more) out = argv[++i];
        else if (arg == "--expression" && more) expression = argv[++i];
        else if (arg == "--closing" && more) closing = std::atof(argv[++i]);
        else if (arg == "--sheet" && more) sheet = argv[++i];
        else { std::fprintf(stderr, "unknown argument: %s\n", arg.c_str()); return 2; }
    }

    if (!sheet.empty()) {
        for (const Named& named : kEmotions) {
            Canvas canvas = render(named.emotion, closing, true);
            const std::string path = sheet + "-" + named.name + ".png";
            if (!writePng(path, canvas.rgb)) { std::fprintf(stderr, "cannot write %s\n", path.c_str()); return 1; }
            std::printf("%s\n", path.c_str());
        }
        return 0;
    }

    for (const Named& named : kEmotions) {
        if (expression == named.name) {
            Canvas canvas = render(named.emotion, closing, true);
            if (!writePng(out, canvas.rgb)) { std::fprintf(stderr, "cannot write %s\n", out.c_str()); return 1; }
            std::printf("%s\n", out.c_str());
            return 0;
        }
    }
    std::fprintf(stderr, "unknown expression: %s\n", expression.c_str());
    return 2;
}
