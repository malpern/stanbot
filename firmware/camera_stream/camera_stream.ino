// Local USB camera stream for StackChan bring-up.
//
// This intentionally contains no Wi-Fi, network stack, motor movement, face
// inference, or persistent frame storage. It emits bounded JPEG frames for the
// Mini companion using the SBFR protocol documented in companion-architecture.

#include <Arduino.h>
#include <M5Unified.h>
#include <ESP_Video.h>
#include <img_converters.h>
#include <esp_rom_sys.h>
#include <esp_log.h>
#include <StanbotEyes.h>
#include <atomic>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <esp_video_ioctl.h>
#include <esp_rom_crc.h>
#include <esp_heap_caps.h>
#include <M5StackChan.h>
#include <drivers/FTServo_Arduino/src/SCSCL.h>
#include <driver/i2c_master.h>

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
constexpr uint32_t kFrameIntervalMs = 200;  // Requests up to 5 fps; measured ~3.5 fps.

ESPVideoCaptureDevClass capture;
uint32_t sequence = 0;
uint32_t nextFrameAtMs = 0;
std::atomic<bool> streamEnabled{false};
std::atomic<uint32_t> frameIntervalMs{kFrameIntervalMs};
// 0: VGA JPEG; 1: QVGA JPEG; 2: benchmark-only QVGA raw YUYV + CRC32.
std::atomic<uint8_t> imageMode{1};
uint8_t* smallFrame = nullptr;
std::atomic<bool> statsRequested{false}, resetStats{false};
std::atomic<bool> servoProbeRequested{false};
std::atomic<bool> powerTestRequested{false};
std::atomic<uint32_t> maxEyeGapMs{0};
uint32_t lastEyeMs = 0;
struct PipelineStats {
  uint32_t startedMs = 0, captures = 0, sent = 0, failures = 0;
  uint64_t captureWaitUs = 0, encodeUs = 0, enqueueUs = 0, jpegBytes = 0;
} stats;
StanbotEyes eyes;
M5Canvas eyeFrame(&M5.Display);
bool eyeFrameReady = false;
char commandLine[48]{};
size_t commandLength = 0;
bool discardCommand = false;
uint32_t lastCommandByteMs = 0;

void pollCommands(uint32_t now) {
  if (commandLength && now - lastCommandByteMs > 1000) {
    commandLength = 0;
    discardCommand = true;
  }
  // Bound input work so a noisy sender cannot starve the avatar.
  for (unsigned i = 0; i < 128 && Serial.available(); ++i) {
    const char c = static_cast<char>(Serial.read());
    lastCommandByteMs = now;
    if (c == '\n') {
      commandLine[commandLength] = '\0';
      if (!discardCommand) {
        if (strcmp(commandLine, "S") == 0) streamEnabled.store(true);
        else if (strcmp(commandLine, "X") == 0) streamEnabled.store(false);
        else if (strcmp(commandLine, "P") == 0) statsRequested.store(true);
        else if (strcmp(commandLine, "Q") == 0) servoProbeRequested.store(true);
        else if (strcmp(commandLine, "C,POWERTEST") == 0) powerTestRequested.store(true);
        else if (strcmp(commandLine, "Z") == 0) {
          resetStats.store(true);
          maxEyeGapMs.store(0);
        }
        else if (strcmp(commandLine, "R,750") == 0) frameIntervalMs.store(750);
        else if (strcmp(commandLine, "R,333") == 0) frameIntervalMs.store(333);
        else if (strcmp(commandLine, "R,200") == 0) frameIntervalMs.store(200);
        else if (strcmp(commandLine, "R,100") == 0) frameIntervalMs.store(100);
        else if (strcmp(commandLine, "M,640") == 0) imageMode.store(0);
        else if (strcmp(commandLine, "M,320") == 0) imageMode.store(1);
        else if (strcmp(commandLine, "M,raw320") == 0) imageMode.store(2);
        else if (strncmp(commandLine, "E,", 2) == 0) {
          StanbotEmotion emotion;
          if (StanbotEyes::emotionFromName(commandLine + 2, emotion)) eyes.setEmotion(emotion);
        }
      }
      commandLength = 0;
      discardCommand = false;
    } else if (c != '\r' && !discardCommand) {
      if (commandLength + 1 < sizeof(commandLine)) commandLine[commandLength++] = c;
      else discardCommand = true;
    }
  }
}

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
  if (!capture.begin(ESP_VIDEO_DVP_DEVICE_NAME, 2)) return false;

  // GC0308 PCLK divider, documented by Espressif's esp32-camera GC0308
  // driver: register 0x28, bits 6:4. Slow the actual pixel bus, not merely
  // the rate at which we forward completed frames. Preserve all other bits.
  const int controlFD = open(ESP_VIDEO_DVP_DEVICE_NAME, O_RDWR);
  if (controlFD < 0) return false;
  auto sensorRegister = [&](uint32_t command, esp_cam_sensor_reg_val_t& reg) {
    v4l2_ext_control control{};
    control.id = command;
    control.size = sizeof(reg);
    control.p_u8 = reinterpret_cast<uint8_t*>(&reg);
    v4l2_ext_controls controls{};
    controls.ctrl_class = V4L2_CTRL_CLASS_ESP_CAM_IOCTL;
    controls.count = 1;
    controls.controls = &control;
    return ioctl(controlFD, VIDIOC_S_EXT_CTRLS, &controls) == 0;
  };
  esp_cam_sensor_reg_val_t page{0xfe, 0};
  esp_cam_sensor_reg_val_t divider{0x28, 0};
  bool ok = sensorRegister(ESP_CAM_SENSOR_IOC_S_REG, page) &&
            sensorRegister(ESP_CAM_SENSOR_IOC_G_REG, divider);
  if (ok) {
    divider.value = (divider.value & ~0x70u) | 0x20u;
    ok = sensorRegister(ESP_CAM_SENSOR_IOC_S_REG, divider);
    divider.value = 0;
    ok = ok && sensorRegister(ESP_CAM_SENSOR_IOC_G_REG, divider) &&
         (divider.value & 0x70u) == 0x20u;
  }
  close(controlFD);
  if (!ok) return false;
  return capture.startCapture();
}

void sendFrame(const ESPVideoBufferClass& frame) {
  uint8_t* jpeg = nullptr;
  size_t jpegLength = 0;
  const uint32_t encodeStart = micros();
  const uint8_t mode = imageMode.load();
  if (mode && !smallFrame) smallFrame = static_cast<uint8_t*>(heap_caps_malloc(320 * 240 * 2, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
  if (mode && (!smallFrame || frame.getWidth() != 640 || frame.getHeight() != 480 || frame.size() != 640 * 480 * 2)) {
    ++stats.failures;
    return;
  }
  if (mode) {
    // Decimate YUYV by two in both dimensions, retaining paired U/V samples.
    for (unsigned y = 0; y < 240; ++y) {
      const uint8_t* src = frame.data() + y * 2 * 640 * 2;
      uint8_t* dst = smallFrame + y * 320 * 2;
      for (unsigned x = 0; x < 160; ++x) {
        dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[4]; dst[3] = src[3];
        src += 8; dst += 4;
      }
    }
  }
  const bool raw = mode == 2;
  bool encoded = true;
  if (raw) { jpeg = smallFrame; jpegLength = 320 * 240 * 2; }
  else encoded = fmt2jpg(mode ? smallFrame : frame.data(), mode ? 320 * 240 * 2 : frame.size(),
                         mode ? 320 : frame.getWidth(), mode ? 240 : frame.getHeight(),
                         PIXFORMAT_YUV422, kJpegQuality, &jpeg, &jpegLength);
  uint8_t checksum[4]{};
  if (raw) putUInt32LE(checksum, esp_rom_crc32_le(0, jpeg, jpegLength));
  stats.encodeUs += static_cast<uint32_t>(micros() - encodeStart);
  if (!encoded || jpeg == nullptr || jpegLength == 0 || jpegLength > kMaxJpegBytes) {
    if (jpeg != nullptr && !raw) free(jpeg);
    ++stats.failures;
    return;
  }

  // A complete JPEG matters more than a high frame count. The host decoder can
  // recover from an interrupted packet, but we never deliberately start a
  // second payload until the first one has drained.
  uint8_t header[13] = {'S', 'B', 'F', 'R', 1};
  header[4] = raw ? 2 : 1;
  putUInt32LE(header + 5, ++sequence);
  putUInt32LE(header + 9, static_cast<uint32_t>(jpegLength + (raw ? 4 : 0)));
  const uint32_t enqueueStart = micros();
  const bool sent = writeFully(header, sizeof(header)) && writeFully(jpeg, jpegLength) &&
                    (!raw || writeFully(checksum, sizeof(checksum)));
  stats.enqueueUs += static_cast<uint32_t>(micros() - enqueueStart);
  if (sent) { ++stats.sent; stats.jpegBytes += jpegLength; }
  else ++stats.failures;
  if (!raw) free(jpeg);
}

SCSCL servoBus;
bool servoBusReady = false;

bool prepareServoBus() {
  if (!servoBusReady) servoBusReady = servoBus.begin(UART_NUM_1, 1000000, 6, 7);
  servoBus.IOTimeOut = 20;
  return servoBusReady;
}

// One power window per boot. No position goals, torque-on, or EEPROM writes.
// The independent cutoff task never waits on USB, camera capture, or servo UART.
struct PowerCutoff {
  i2c_master_dev_handle_t device = nullptr;
  uint8_t offValue = 0;
  std::atomic<bool> done{false};
  std::atomic<bool> written{false};
  std::atomic<bool> release{false};
} powerCutoff;

bool writeBase(i2c_master_dev_handle_t device, uint8_t reg, uint8_t value) {
  const uint8_t bytes[] = {reg, value};
  return i2c_master_transmit(device, bytes, sizeof(bytes), 100) == ESP_OK;
}

void cutoffTask(void*) {
  ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(2000));
  bool written = false;
  for (int attempt = 0; attempt < 3 && !written; ++attempt)
    written = writeBase(powerCutoff.device, 0x05, powerCutoff.offValue);
  powerCutoff.written.store(written);
  powerCutoff.done.store(true);
  while (!powerCutoff.release.load()) vTaskDelay(1);
  vTaskDelete(nullptr);
}

void testServoPower() {
  static bool attempted = false;
  if (attempted || streamEnabled.load()) {
    Serial.println("SBPW {\"error\":\"requires_stopped_stream_and_unused_boot\"}");
    return;
  }
  attempted = true;
  i2c_master_bus_handle_t master = nullptr;
  i2c_master_dev_handle_t device = nullptr;
  i2c_device_config_t config{};
  config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
  config.device_address = 0x6f;
  config.scl_speed_hz = 100000;
  uint8_t regs[11]{}; // 0x02..0x0c: version through pull-down settings.
  const uint8_t start = 0x02;
  bool ready = prepareServoBus() &&
    i2c_master_get_bus_handle(kSccbPort, &master) == ESP_OK &&
    i2c_master_bus_add_device(master, &config, &device) == ESP_OK &&
    i2c_master_transmit_receive(device, &start, 1, regs, sizeof(regs), 100) == ESP_OK;
  // Refuse a base already driving VM high; this test must start from off.
  ready = ready && regs[0] != 0 && regs[0] != 255 && !(regs[3] & 1) && !(regs[5] & 1);
  const uint8_t off = regs[3] & ~1u;
  if (ready) ready = writeBase(device, 0x05, off) && writeBase(device, 0x03, regs[1] | 1u);
  // Match the official BSP: VM output with pull-up, no pull-down. Keep VM low
  // throughout configuration, and preserve every other pin's settings.
  if (ready) ready = writeBase(device, 0x0b, regs[9] & ~1u) && writeBase(device, 0x09, regs[7] | 1u);
  uint8_t configured[11]{};
  if (ready) ready = i2c_master_transmit_receive(device, &start, 1, configured, sizeof(configured), 100) == ESP_OK &&
    (configured[1] & 1) && !(configured[3] & 1) && !(configured[5] & 1) &&
    (configured[7] & 1) && !(configured[9] & 1);
  if (!ready) {
    if (device) i2c_master_bus_rm_device(device);
    Serial.println("SBPW {\"error\":\"preflight_failed_no_power_enabled\"}");
    return;
  }
  powerCutoff.device = device;
  powerCutoff.offValue = off;
  powerCutoff.done.store(false);
  powerCutoff.written.store(false);
  powerCutoff.release.store(false);
  TaskHandle_t cutoff = nullptr;
  if (xTaskCreatePinnedToCore(cutoffTask, "servo-cutoff", 3072, nullptr, 5, &cutoff, 1) != pdPASS) {
    i2c_master_bus_rm_device(device);
    Serial.println("SBPW {\"error\":\"cutoff_task_unavailable_no_power_enabled\"}");
    return;
  }
  // Broadcast torque-off before and repeatedly during the boot window.
  servoBus.EnableTorque(0xfe, 0);
  const uint32_t started = millis();
  bool enabled = writeBase(device, 0x05, off | 1u);
  uint8_t onState[6]{};
  const uint8_t modeReg = 0x03;
  bool onVerified = enabled && i2c_master_transmit_receive(device, &modeReg, 1, onState, sizeof(onState), 100) == ESP_OK &&
    (onState[0] & 1) && (onState[2] & 1) && (onState[4] & 1);
  struct Reading { int position = -1, torque = -1, minimum = -1, maximum = -1, moving = -1; } readings[2];
  if (onVerified) {
    for (int i = 0; i < 10; ++i) {
      servoBus.EnableTorque(0xfe, 0);
      vTaskDelay(pdMS_TO_TICKS(20));
    }
    for (int id = 1; id <= 2; ++id) {
      servoBus.EnableTorque(id, 0);
      auto& r = readings[id - 1];
      r.torque = servoBus.readByte(id, SCSCL_TORQUE_ENABLE);
      if (r.torque != 0) break;
      r.position = servoBus.ReadPos(id);
      r.minimum = servoBus.readWord(id, SCSCL_MIN_ANGLE_LIMIT_L);
      r.maximum = servoBus.readWord(id, SCSCL_MAX_ANGLE_LIMIT_L);
      r.moving = servoBus.ReadMove(id);
    }
  }
  // The task stays alive until release, even if its deadline already fired.
  xTaskNotifyGive(cutoff);
  while (!powerCutoff.done.load()) vTaskDelay(1);
  uint8_t after[4]{};
  const uint8_t outReg = 0x05;
  bool readback = i2c_master_transmit_receive(device, &outReg, 1, after, sizeof(after), 100) == ESP_OK;
  bool offVerified = powerCutoff.written.load() && readback && !(after[0] & 1) && !(after[2] & 1);
  i2c_master_bus_rm_device(device);
  powerCutoff.release.store(true);
  // No USB output while power is enabled: a stalled host cannot delay cutoff.
  for (int id = 1; id <= 2; ++id) {
    auto& r = readings[id - 1];
    Serial.printf("SBSC {\"id\":%d,\"position\":%d,\"torque\":%d,\"minimum\":%d,\"maximum\":%d,\"moving\":%d,\"read_only\":false}\n",
                  id, r.position, r.torque, r.minimum, r.maximum, r.moving);
  }
  Serial.printf("SBPW {\"power_write_ack\":%s,\"enable_high_verified\":%s,\"power_off_verified\":%s,\"elapsed_ms\":%lu,\"position_commands\":0}\n",
                enabled ? "true" : "false", onVerified ? "true" : "false", offVerified ? "true" : "false", (unsigned long)(millis() - started));
}

void probeServos() {
  // Read the base expander using the camera's existing I2C bus, on its owner task.
  // Never reinitialize M5.In_I2C while the camera owns this peripheral.
  i2c_master_bus_handle_t master = nullptr;
  i2c_master_dev_handle_t device = nullptr;
  i2c_device_config_t config{};
  config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
  config.device_address = 0x6f;
  config.scl_speed_hz = 100000;
  esp_err_t status = i2c_master_get_bus_handle(kSccbPort, &master);
  if (status == ESP_OK) status = i2c_master_bus_add_device(master, &config, &device);
  uint8_t registers[7]{};
  const uint8_t startRegister = 0x02; // BSP: version, direction, output, input.
  if (status == ESP_OK) status = i2c_master_transmit_receive(device, &startRegister, 1, registers, sizeof(registers), 100);
  if (device) i2c_master_bus_rm_device(device);
  if (status == ESP_OK) {
    Serial.printf("SBSC {\"base\":true,\"version\":%u,\"vm_output_mode\":%u,\"vm_output_latch\":%u,\"vm_input_level\":%u,\"read_only\":true}\n",
                  registers[0], registers[1] & 1, registers[3] & 1, registers[5] & 1);
  } else {
    Serial.printf("SBSC {\"base\":true,\"error\":%d,\"read_only\":true}\n", status);
  }
  // Never call M5StackChan.begin(): it enables motor power.
  // Do not write goals, torque, modes, offsets, or EEPROM. Missing feedback is
  // an explicit failure, never a substitute position or permission to move.
  if (!prepareServoBus()) { Serial.println("SBSC {\"error\":\"uart_unavailable\"}"); return; }
  auto& bus = servoBus;
  for (int id = 1; id <= 2; ++id) {
    int position = bus.ReadPos(id);
    int torque = bus.readByte(id, SCSCL_TORQUE_ENABLE);
    int minimum = bus.readWord(id, SCSCL_MIN_ANGLE_LIMIT_L);
    int maximum = bus.readWord(id, SCSCL_MAX_ANGLE_LIMIT_L);
    int moving = bus.ReadMove(id);
    Serial.printf("SBSC {\"id\":%d,\"position\":%d,\"torque\":%d,\"minimum\":%d,\"maximum\":%d,\"moving\":%d,\"read_only\":true}\n",
                  id, position, torque, minimum, maximum, moving);
  }
}

void cameraTask(void*) {
  // Camera capture/JPEG/USB can block; they never own the display or eyes.
  if (!beginCamera()) {
    Serial.println("CAMERA_STREAM_INIT_FAILED");
    vTaskDelete(nullptr);
    return;
  }
  Serial.println("CAMERA_STREAM_READY protocol=SBFR/jpeg/local-only emotions=18 motion=disabled");
  stats.startedMs = millis();
  for (;;) {
    // Only the camera task writes USB, and diagnostics appear between packets.
    if (powerTestRequested.exchange(false)) testServoPower();
    if (servoProbeRequested.exchange(false)) probeServos();
    if (resetStats.exchange(false)) { stats = {}; stats.startedMs = millis(); nextFrameAtMs = 0; }
    if (statsRequested.exchange(false)) {
      Serial.printf("SBST {\"elapsed_ms\":%lu,\"captures\":%lu,\"sent\":%lu,\"failures\":%lu,\"capture_wait_us\":%llu,\"encode_us\":%llu,\"enqueue_us\":%llu,\"jpeg_bytes\":%llu,\"max_eye_gap_ms\":%lu}\n",
        (unsigned long)(millis() - stats.startedMs), (unsigned long)stats.captures,
        (unsigned long)stats.sent, (unsigned long)stats.failures,
        (unsigned long long)stats.captureWaitUs, (unsigned long long)stats.encodeUs,
        (unsigned long long)stats.enqueueUs, (unsigned long long)stats.jpegBytes,
        (unsigned long)maxEyeGapMs.load());
    }
    const uint32_t captureStart = micros();
    ESPVideoBufferClass frame = capture.captureBuffer();
    stats.captureWaitUs += static_cast<uint32_t>(micros() - captureStart);
    if (frame.valid()) {
      ++stats.captures;
      const uint32_t now = millis();
      if (streamEnabled.load() && static_cast<int32_t>(now - nextFrameAtMs) >= 0) {
        nextFrameAtMs = now + frameIntervalMs.load();
        sendFrame(frame);
      }
    }
    vTaskDelay(1);
  }
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
  M5.Display.setRotation(1);
  M5.Display.fillScreen(TFT_BLACK);
  eyeFrame.setColorDepth(16);
  eyeFrameReady = eyeFrame.createSprite(M5.Display.width(), M5.Display.height());
  eyes.begin(millis() - 34);
  if (eyeFrameReady && eyes.update(eyeFrame, millis())) eyeFrame.pushSprite(0, 0);
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
  if (xTaskCreatePinnedToCore(cameraTask, "camera", 8192, nullptr, 1, nullptr, 0) != pdPASS) {
    Serial.println("CAMERA_TASK_FAILED");
  }
}

void loop() {
  const uint32_t now = millis();
  pollCommands(now);
  if (eyeFrameReady) {
    if (eyes.update(eyeFrame, now)) {
      eyeFrame.pushSprite(0, 0);
      const uint32_t presentedMs = millis();
      if (lastEyeMs) {
        const uint32_t gap = presentedMs - lastEyeMs;
        uint32_t old = maxEyeGapMs.load();
        while (gap > old && !maxEyeGapMs.compare_exchange_weak(old, gap)) {}
      }
      lastEyeMs = presentedMs;
    }
  } else {
    eyes.update(M5.Display, now);
  }
  // Do not call M5.update(): the video task exclusively owns internal I2C.
  delay(5);
}
