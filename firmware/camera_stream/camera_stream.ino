// Local USB camera stream for StackChan bring-up.
//
// This intentionally contains no Wi-Fi, network stack, motor code, face
// inference, or persistent frame storage. It emits bounded JPEG frames for the
// Mini companion using the SBFR protocol documented in companion-architecture.

#include <Arduino.h>
#include <M5Unified.h>
#include <ESP_Video.h>
#include <img_converters.h>
#include <esp_rom_sys.h>
#include <esp_log.h>

namespace {

constexpr int kSccbPort = 0;
constexpr int kSccbScl = 11;
constexpr int kSccbSda = 12;
constexpr int kVsync = 46;
constexpr int kHref = 38;
constexpr int kPclk = 45;
constexpr int kExternalXclk = -1;  // Fixed external 20 MHz clock.
constexpr int kDataPins[] = {39, 40, 41, 42, 15, 16, 48, 47};
constexpr uint8_t kJpegQuality = 35;
constexpr size_t kMaxJpegBytes = 300000;
constexpr uint32_t kFrameIntervalMs = 750;  // Conservative ~1.3 fps for bring-up.

ESPVideoCaptureDevClass capture;
uint32_t sequence = 0;
uint32_t nextFrameAtMs = 0;
bool streamEnabled = false;

void putUInt32LE(uint8_t* bytes, uint32_t value) {
  bytes[0] = static_cast<uint8_t>(value & 0xff);
  bytes[1] = static_cast<uint8_t>((value >> 8) & 0xff);
  bytes[2] = static_cast<uint8_t>((value >> 16) & 0xff);
  bytes[3] = static_cast<uint8_t>((value >> 24) & 0xff);
}

bool writeFully(const uint8_t* bytes, size_t length) {
  const uint32_t deadline = millis() + 1500;
  size_t offset = 0;
  while (offset < length && millis() < deadline) {
    const size_t written = Serial.write(bytes + offset, length - offset);
    if (written == 0) {
      delay(1);
      continue;
    }
    offset += written;
  }
  return offset == length;
}

bool beginCamera() {
  static esp_cam_ctlr_dvp_pin_config_t pins = {
      .data_width = CAM_CTLR_DATA_WIDTH_8,
      .data_io = {static_cast<gpio_num_t>(kDataPins[0]), static_cast<gpio_num_t>(kDataPins[1]),
                  static_cast<gpio_num_t>(kDataPins[2]), static_cast<gpio_num_t>(kDataPins[3]),
                  static_cast<gpio_num_t>(kDataPins[4]), static_cast<gpio_num_t>(kDataPins[5]),
                  static_cast<gpio_num_t>(kDataPins[6]), static_cast<gpio_num_t>(kDataPins[7])},
      .vsync_io = static_cast<gpio_num_t>(kVsync),
      .de_io = static_cast<gpio_num_t>(kHref),
      .pclk_io = static_cast<gpio_num_t>(kPclk),
      .xclk_io = static_cast<gpio_num_t>(kExternalXclk),
  };
  static esp_video_init_dvp_config_t dvpConfig = {
      .sccb_config = {.init_sccb = true,
                      .i2c_config = {.port = kSccbPort,
                                     .scl_pin = static_cast<gpio_num_t>(kSccbScl),
                                     .sda_pin = static_cast<gpio_num_t>(kSccbSda)},
                      .freq = 100000},
      .reset_pin = GPIO_NUM_NC,
      .pwdn_pin = GPIO_NUM_NC,
      .dvp_pin = pins,
      .xclk_freq = 20000000,
  };
  static esp_video_init_config_t videoConfig = {.dvp = &dvpConfig};
  if (esp_video_init_with_flags(&videoConfig, ESP_VIDEO_INIT_FLAGS_DVP) != ESP_OK) return false;
  return capture.begin(ESP_VIDEO_DVP_DEVICE_NAME, 2) && capture.startCapture();
}

void sendFrame(const ESPVideoBufferClass& frame) {
  uint8_t* jpeg = nullptr;
  size_t jpegLength = 0;
  const bool encoded = fmt2jpg(frame.data(), frame.size(), frame.getWidth(), frame.getHeight(),
                                PIXFORMAT_YUV422, kJpegQuality, &jpeg, &jpegLength);
  if (!encoded || jpeg == nullptr || jpegLength == 0 || jpegLength > kMaxJpegBytes) {
    if (jpeg != nullptr) free(jpeg);
    return;
  }

  // A complete JPEG matters more than a high frame count. The host decoder can
  // recover from an interrupted packet, but we never deliberately start a
  // second payload until the first one has drained.
  uint8_t header[13] = {'S', 'B', 'F', 'R', 1};
  putUInt32LE(header + 5, ++sequence);
  putUInt32LE(header + 9, static_cast<uint32_t>(jpegLength));
  if (writeFully(header, sizeof(header))) writeFully(jpeg, jpegLength);
  free(jpeg);
}

}  // namespace

void setup() {
  // Initialize CoreS3 power rails and camera reset through M5's official
  // board driver. A warm flash can inherit these settings; a cold boot cannot.
  // Do not call the StackChan BSP begin(): that also enables the servo rail.
  auto config = M5.config();
  config.internal_spk = false;
  config.internal_mic = false;
  config.internal_imu = false;
  config.internal_rtc = false;
  M5.begin(config);
  M5.Display.fillScreen(TFT_BLACK);
  M5.Display.setTextColor(TFT_WHITE, TFT_BLACK);
  M5.Display.setTextSize(2);
  M5.Display.setCursor(20, 80);
  M5.Display.println("Camera starting...");
  // Give the video driver sole ownership of the internal SCCB/I2C bus.
  M5.In_I2C.release();
  Serial.begin(921600);
  // ROM camera ISR warnings otherwise interleave with binary JPEG payloads
  // on USB Serial/JTAG. Reserve that transport exclusively for our protocol.
  // Capture overruns still require performance work; silencing their console
  // text protects framing, it does not resolve the underlying overruns.
  esp_log_level_set("*", ESP_LOG_NONE);
  esp_rom_install_channel_putc(1, nullptr);
  esp_rom_install_channel_putc(2, nullptr);
  if (!beginCamera()) {
    M5.Display.setCursor(20, 120);
    M5.Display.println("Camera init failed");
    Serial.println("CAMERA_STREAM_INIT_FAILED");
    return;
  }
  M5.Display.setCursor(20, 120);
  M5.Display.println("Ready for Mac");
  Serial.println("CAMERA_STREAM_READY protocol=SBFR/jpeg/local-only");
}

void loop() {
  // The Mini must explicitly enable the camera stream. This avoids filling USB
  // buffers before it has opened a reader and works with native macOS file
  // handles that do not assert a modem-control line.
  while (Serial.available()) {
    const char command = static_cast<char>(Serial.read());
    if (command == 'S') streamEnabled = true;
    if (command == 'X') streamEnabled = false;
  }
  if (!capture.isCaptureStarted()) {
    delay(250);
    return;
  }

  ESPVideoBufferClass frame = capture.captureBuffer();
  if (!frame.valid()) return;

  const uint32_t now = millis();
  if (streamEnabled && now >= nextFrameAtMs) {
    nextFrameAtMs = now + kFrameIntervalMs;
    sendFrame(frame);
  }
}
