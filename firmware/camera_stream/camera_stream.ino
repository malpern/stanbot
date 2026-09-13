// Local USB camera stream for StackChan bring-up.
//
// This intentionally contains no Wi-Fi, network stack, motor code, face
// inference, or persistent frame storage. It emits bounded JPEG frames for the
// Mini companion using the SBFR protocol documented in companion-architecture.

#include <Arduino.h>
#include <ESP_Video.h>
#include <img_converters.h>

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
  // USB CDC's truthy state requires the host to have opened the device. Do not
  // create a partial packet while the Mini app is not listening.
  if (!Serial) return;
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
  Serial.begin(921600);
  if (!beginCamera()) {
    Serial.println("CAMERA_STREAM_INIT_FAILED");
    return;
  }
  Serial.println("CAMERA_STREAM_READY protocol=SBFR/jpeg/local-only");
}

void loop() {
  if (!capture.isCaptureStarted()) {
    delay(250);
    return;
  }

  ESPVideoBufferClass frame = capture.captureBuffer();
  if (!frame.valid()) return;

  const uint32_t now = millis();
  if (now >= nextFrameAtMs) {
    nextFrameAtMs = now + kFrameIntervalMs;
    sendFrame(frame);
  }
}
