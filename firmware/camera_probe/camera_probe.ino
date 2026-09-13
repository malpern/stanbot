// StackChan camera bring-up probe. This is intentionally separate from the
// main firmware so camera hardware can be validated before transport is added.
// No frame data leaves the USB serial link in this probe.

#include <Arduino.h>
#include <ESP_Video.h>

constexpr int kSccbPort = 0;
constexpr int kSccbScl = 11;  // CoreS3 internal I2C; matches StackChan BSP.
constexpr int kSccbSda = 12;
constexpr int kVsync = 46;
constexpr int kHref = 38;
constexpr int kPclk = 45;
constexpr int kExternalXclk = -1;  // StackChan supplies a fixed 20 MHz clock.
constexpr int kDataPins[] = {39, 40, 41, 42, 15, 16, 48, 47};

ESPVideoCaptureDevClass capture;
const char* initFailure = "not_started";
uint32_t frameCount = 0;

void setup() {
  Serial.begin(115200);
  // ESPVideoClass reserves an XCLK pin through Arduino's peripheral manager.
  // StackChan has a dedicated external 20 MHz XCLK and therefore no GPIO to
  // reserve. Use the underlying Espressif configuration directly, matching
  // StackChan's official BSP.
  static esp_cam_ctlr_dvp_pin_config_t pins = {
      .data_width = CAM_CTLR_DATA_WIDTH_8,
      .data_io = {static_cast<gpio_num_t>(kDataPins[0]),
                  static_cast<gpio_num_t>(kDataPins[1]),
                  static_cast<gpio_num_t>(kDataPins[2]),
                  static_cast<gpio_num_t>(kDataPins[3]),
                  static_cast<gpio_num_t>(kDataPins[4]),
                  static_cast<gpio_num_t>(kDataPins[5]),
                  static_cast<gpio_num_t>(kDataPins[6]),
                  static_cast<gpio_num_t>(kDataPins[7])},
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
  const esp_err_t videoResult =
      esp_video_init_with_flags(&videoConfig, ESP_VIDEO_INIT_FLAGS_DVP);
  if (videoResult != ESP_OK) {
    initFailure = "video";
    Serial.printf("CAMERA_PROBE_INIT_FAILED stage=video err=%s\n",
                  esp_err_to_name(videoResult));
    return;
  }
  if (!capture.begin(ESP_VIDEO_DVP_DEVICE_NAME, 2)) {
    initFailure = "capture_open";
    Serial.println("CAMERA_PROBE_INIT_FAILED stage=capture_open");
    return;
  }
  if (!capture.startCapture()) {
    initFailure = "capture_start";
    Serial.println("CAMERA_PROBE_INIT_FAILED stage=capture_start");
    return;
  }
  Serial.println("CAMERA_PROBE_READY");
}

void loop() {
  if (!capture.isCaptureStarted()) {
    Serial.printf("CAMERA_PROBE_NOT_READY stage=%s\n", initFailure);
    delay(1000);
    return;
  }
  ESPVideoBufferClass frame = capture.captureBuffer();
  if (!frame.valid()) {
    Serial.println("CAMERA_PROBE_FRAME_FAILED");
    delay(100);
    return;
  }
  // Drain the live camera stream continuously. Reporting every frame over USB
  // would itself make the consumer too slow and cause capture overflow.
  if (++frameCount % 30 == 0) {
    Serial.printf("CAMERA_FRAME count=%lu bytes=%lu format=%s width=%lu height=%lu\n",
                  static_cast<unsigned long>(frameCount),
                  static_cast<unsigned long>(frame.size()), frame.formatName(),
                  static_cast<unsigned long>(frame.getWidth()),
                  static_cast<unsigned long>(frame.getHeight()));
  }
}
