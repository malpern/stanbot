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
#include "downsample.h"

namespace {

constexpr int kSccbPort = 0;
constexpr int kSccbScl = 11;
constexpr int kSccbSda = 12;
constexpr int kVsync = 46;
constexpr int kHref = 38;
constexpr int kPclk = 45;
constexpr int kExternalXclk = -1;  // Fixed external 20 MHz clock.
constexpr int kDataPins[] = {39, 40, 41, 42, 15, 16, 48, 47};
// Chosen by measurement, not taste: see docs/camera-performance.md. At QVGA
// every value from 50 to 90 held the same 3.50 fps, because the rate is capped
// by sensor capture rather than by encoding or the USB link, which sits near
// 8% utilised even here. 90 triples the bitrate of the old 35 for free. At VGA
// the same value does cost frame rate, since encode time grows with it.
constexpr uint8_t kJpegQuality = 90;
constexpr size_t kMaxJpegBytes = 300000;
constexpr uint32_t kFrameIntervalMs = 200;  // Requests up to 5 fps; measured ~3.5 fps.

ESPVideoCaptureDevClass capture;
uint32_t sequence = 0;
uint32_t nextFrameAtMs = 0;
std::atomic<bool> streamEnabled{false};
std::atomic<uint32_t> frameIntervalMs{kFrameIntervalMs};
// 0: VGA JPEG; 1: QVGA JPEG; 2: benchmark-only QVGA raw YUYV + CRC32.
std::atomic<uint8_t> imageMode{1};
std::atomic<uint8_t> jpegQuality{kJpegQuality};
uint8_t* smallFrame = nullptr;
std::atomic<bool> statsRequested{false}, resetStats{false};
std::atomic<bool> servoProbeRequested{false};
std::atomic<bool> powerTestRequested{false};
std::atomic<bool> powerOffRequested{false};
std::atomic<bool> yawTestRequested{false};
std::atomic<bool> yawBackRequested{false};
std::atomic<bool> yawSessionRequested{false};
std::atomic<bool> yawRampRequested{false};
std::atomic<bool> yawSweepRequested{false};
std::atomic<bool> yawCenterRequested{false};
std::atomic<bool> pitchNudgeRequested{false};
std::atomic<bool> rebootRequested{false};
bool disableOnlyLatched = false; // Owner task only; blocks enable tests until reboot.
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
        else if (strcmp(commandLine, "C,POWEROFF") == 0) powerOffRequested.store(true);
        else if (strcmp(commandLine, "C,YAWTEST") == 0) yawTestRequested.store(true);
        else if (strcmp(commandLine, "C,YAWBACK") == 0) yawBackRequested.store(true);
        else if (strcmp(commandLine, "C,YAWSESSION") == 0) yawSessionRequested.store(true);
        else if (strcmp(commandLine, "C,YAWRAMP") == 0) yawRampRequested.store(true);
        else if (strcmp(commandLine, "C,YAWSWEEP") == 0) yawSweepRequested.store(true);
        else if (strcmp(commandLine, "C,CENTER") == 0) yawCenterRequested.store(true);
        else if (strcmp(commandLine, "C,PITCHNUDGE") == 0) pitchNudgeRequested.store(true);
        else if (strcmp(commandLine, "C,REBOOT") == 0) rebootRequested.store(true);
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
        else if (strncmp(commandLine, "J,", 2) == 0) {
          // Diagnostic sweep of the encoder quality, bounded to sane values.
          const long value = strtol(commandLine + 2, nullptr, 10);
          if (value >= 10 && value <= 95) jpegQuality.store(static_cast<uint8_t>(value));
        }
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
    boxAverageYuyvHalf(frame.data(), smallFrame);
  }
  const bool raw = mode == 2;
  bool encoded = true;
  if (raw) { jpeg = smallFrame; jpegLength = 320 * 240 * 2; }
  else encoded = fmt2jpg(mode ? smallFrame : frame.data(), mode ? 320 * 240 * 2 : frame.size(),
                         mode ? 320 : frame.getWidth(), mode ? 240 : frame.getHeight(),
                         PIXFORMAT_YUV422, jpegQuality.load(), &jpeg, &jpegLength);
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
  uint32_t deadlineMs = 2000; // Set before task creation; never extended in flight.
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

// Match the BSP's single-register reads; do not assume auto-increment support.
esp_err_t readBaseRegisters(i2c_master_dev_handle_t device, uint8_t start,
                            uint8_t* values, size_t count) {
  for (size_t i = 0; i < count; ++i) {
    const uint8_t reg = start + i;
    esp_err_t result = i2c_master_transmit_receive(device, &reg, 1, values + i, 1, 100);
    if (result != ESP_OK) return result;
  }
  return ESP_OK;
}

struct EnableSnapshot {
  uint8_t mode = 0, latch = 0, input = 0;
  esp_err_t modeError = ESP_ERR_INVALID_STATE;
  esp_err_t latchError = ESP_ERR_INVALID_STATE;
  esp_err_t inputError = ESP_ERR_INVALID_STATE;
  bool outputHigh() const {
    // GPIO input stayed low with communicating servos and after disable.
    // Verify configuration only; this is not a physical supply measurement.
    return modeError == ESP_OK && latchError == ESP_OK &&
      (mode & 1) && (latch & 1);
  }
};

EnableSnapshot readEnable(i2c_master_dev_handle_t device) {
  EnableSnapshot state;
  state.modeError = readBaseRegisters(device, 0x03, &state.mode, 1);
  state.latchError = readBaseRegisters(device, 0x05, &state.latch, 1);
  state.inputError = readBaseRegisters(device, 0x07, &state.input, 1);
  return state;
}

void printEnable(const char* phase, const EnableSnapshot& state) {
  Serial.printf("SBPD {\"phase\":\"%s\",\"mode\":%u,\"latch\":%u,\"input\":%u,\"mode_error\":%d,\"latch_error\":%d,\"input_error\":%d}\n",
    phase, state.mode, state.latch, state.input,
    state.modeError, state.latchError, state.inputError);
}

#include "session_guard.h"

void cutoffTask(void*) {
  ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(powerCutoff.deadlineMs));
  bool written = false;
  for (int attempt = 0; attempt < 3 && !written; ++attempt)
    written = writeBase(powerCutoff.device, 0x05, powerCutoff.offValue);
  powerCutoff.written.store(written);
  powerCutoff.done.store(true);
  while (!powerCutoff.release.load()) vTaskDelay(1);
  vTaskDelete(nullptr);
}

// One motor-power window per boot, shared by every power/motion test.
bool powerWindowUsed = false;

// Shared preflight for a motor-power window: base expander answers, VM is low,
// VM becomes a pull-up output (official BSP setup), and the independent cutoff
// task is armed with `deadlineMs`. Nothing is enabled on failure; the SBPW
// error line is printed here. On success `device` and `off` are valid and the
// caller owns enabling, disabling and releasing the window.
bool openPowerWindow(i2c_master_dev_handle_t& device, uint8_t& off, uint32_t deadlineMs, TaskHandle_t& cutoff) {
  i2c_master_bus_handle_t master = nullptr;
  device = nullptr;
  cutoff = nullptr;
  i2c_device_config_t config{};
  config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
  config.device_address = 0x6f;
  config.scl_speed_hz = 100000;
  uint8_t regs[11]{}; // 0x02..0x0c: version through pull-down settings.
  const uint8_t start = 0x02;
  bool ready = prepareServoBus() &&
    i2c_master_get_bus_handle(kSccbPort, &master) == ESP_OK &&
    i2c_master_bus_add_device(master, &config, &device) == ESP_OK &&
    readBaseRegisters(device, start, regs, sizeof(regs)) == ESP_OK;
  // Refuse a base already driving VM high; this test must start from off.
  ready = ready && regs[0] != 0 && regs[0] != 255 && !(regs[3] & 1);
  off = regs[3] & ~1u;
  if (ready) ready = writeBase(device, 0x05, off) && writeBase(device, 0x03, regs[1] | 1u);
  // Match the official BSP: VM output with pull-up, no pull-down. Keep VM low
  // throughout configuration, and preserve every other pin's settings.
  if (ready) ready = writeBase(device, 0x0b, regs[9] & ~1u) && writeBase(device, 0x09, regs[7] | 1u);
  uint8_t configured[11]{};
  if (ready) ready = readBaseRegisters(device, start, configured, sizeof(configured)) == ESP_OK &&
    (configured[1] & 1) && !(configured[3] & 1) &&
    (configured[7] & 1) && !(configured[9] & 1);
  if (!ready) {
    if (device) i2c_master_bus_rm_device(device);
    device = nullptr;
    Serial.println("SBPW {\"error\":\"preflight_failed_no_power_enabled\"}");
    return false;
  }
  powerCutoff.device = device;
  powerCutoff.deadlineMs = deadlineMs;
  powerCutoff.offValue = off;
  powerCutoff.done.store(false);
  powerCutoff.written.store(false);
  powerCutoff.release.store(false);
  if (xTaskCreatePinnedToCore(cutoffTask, "servo-cutoff", 3072, nullptr, 5, &cutoff, 1) != pdPASS) {
    i2c_master_bus_rm_device(device);
    device = nullptr;
    Serial.println("SBPW {\"error\":\"cutoff_task_unavailable_no_power_enabled\"}");
    return false;
  }
  return true;
}

struct ServoReading {
  int position = -1, torque = -1, minimum = -1, maximum = -1, moving = -1, voltage = -1;
  unsigned attempts = 0;
  int readyAtMs = -1;
  int cwDead = -1, ccwDead = -1;
  int gainP = -1, gainD = -1, gainI = -1, punch = -1; // EEPROM 21..25, read only.
};

// Startup readiness for both servos after VM enable: retry missing replies
// within ONE window (factory startup does RGB/RTC/IMU first), never repower.
// An explicit torque-on reply stops the sequence. Reads only.
void readStartupReadiness(ServoReading* readings, uint32_t started) {
  for (int id = 1; id <= 2; ++id) {
    if (powerCutoff.done.load()) break;
    auto& r = readings[id - 1];
    while (!powerCutoff.done.load() && millis() - started < 1200) {
      servoBus.EnableTorque(0xfe, 0);
      servoBus.EnableTorque(id, 0);
      ++r.attempts;
      r.torque = servoBus.readByte(id, SCSCL_TORQUE_ENABLE);
      if (r.torque != -1) break;
      vTaskDelay(pdMS_TO_TICKS(25));
    }
    if (powerCutoff.done.load()) break;
    if (r.torque != 0) break;
    r.readyAtMs = millis() - started;
    r.position = servoBus.ReadPos(id);
    r.minimum = servoBus.readWord(id, SCSCL_MIN_ANGLE_LIMIT_L);
    r.maximum = servoBus.readWord(id, SCSCL_MAX_ANGLE_LIMIT_L);
    r.moving = servoBus.ReadMove(id);
    r.voltage = servoBus.ReadVoltage(id);
    r.cwDead = servoBus.readByte(id, SCSCL_CW_DEAD);
    r.ccwDead = servoBus.readByte(id, SCSCL_CCW_DEAD);
    r.gainP = servoBus.readByte(id, 21);
    r.gainD = servoBus.readByte(id, 22);
    r.gainI = servoBus.readByte(id, 23);
    r.punch = servoBus.readWord(id, 24);
  }
}

void printReadiness(const ServoReading* readings, const int* offVoltage) {
  for (int id = 1; id <= 2; ++id) {
    const auto& r = readings[id - 1];
    Serial.printf("SBPD {\"phase\":\"startup_readiness\",\"id\":%d,\"attempts\":%u,\"torque_off_at_ms\":%d}\n",
                  id, r.attempts, r.readyAtMs);
    Serial.printf("SBPD {\"phase\":\"deadband\",\"id\":%d,\"cw_raw\":%d,\"ccw_raw\":%d}\n",
                  id, r.cwDead, r.ccwDead);
    Serial.printf("SBPD {\"phase\":\"gains\",\"id\":%d,\"p\":%d,\"d\":%d,\"i\":%d,\"punch\":%d}\n",
                  id, r.gainP, r.gainD, r.gainI, r.punch);
    Serial.printf("SBPD {\"phase\":\"power_window_voltage\",\"id\":%d,\"enabled_raw\":%d,\"after_cutoff_raw\":%d}\n",
                  id, r.voltage, offVoltage[id - 1]);
    Serial.printf("SBSC {\"id\":%d,\"position\":%d,\"torque\":%d,\"minimum\":%d,\"maximum\":%d,\"moving\":%d,\"read_only\":false}\n",
                  id, r.position, r.torque, r.minimum, r.maximum, r.moving);
  }
}

void testServoPower(bool yawTest = false, int yawDelta = 8, bool session = false, bool ramp = false) {
  if (disableOnlyLatched || powerWindowUsed || streamEnabled.load()) {
    Serial.println("SBPW {\"error\":\"requires_stopped_stream_and_unused_boot\"}");
    return;
  }
  powerWindowUsed = true;
  i2c_master_dev_handle_t device = nullptr;
  uint8_t off = 0;
  TaskHandle_t cutoff = nullptr;
  if (!openPowerWindow(device, off, session ? 4000 : 2000, cutoff)) return;
  // Broadcast torque-off before and repeatedly during the boot window.
  servoBus.EnableTorque(0xfe, 0);
  const uint32_t started = millis();
  bool enabled = writeBase(device, 0x05, off | 1u);
  const EnableSnapshot immediate = readEnable(device);
  // Official startup waits 200 ms after enable. Capture immediate state for
  // diagnosis; input level is telemetry, not a supply-present predicate.
  // The independent cutoff remains armed throughout; no USB writes here.
  const uint32_t settleStarted = millis();
  while (enabled && !powerCutoff.done.load() && millis() - settleStarted < 200) {
    servoBus.EnableTorque(0xfe, 0);
    vTaskDelay(pdMS_TO_TICKS(20));
  }
  const EnableSnapshot settled = readEnable(device);
  bool onVerified = enabled && !powerCutoff.done.load() && settled.outputHigh();
  ServoReading readings[2];
  if (onVerified) readStartupReadiness(readings, started);
  // Optional supervised yaw-only nudge, never part of ordinary POWERTEST.
  // Absolute guard is a narrow region around the user-observed factory center,
  // NOT a claim that EEPROM limits describe safe physical travel.
  const char* yawResult = "not_requested";
  int yawStart = -1, yawEnd = -1, yawGoal = -1, positionCommands = 0;
  int stableMin = -1, stableMax = -1, stableSamples = 0;
  int goalReadback = -1, goalStatus = -1, goalError = -1;
  struct TracePoint { uint32_t elapsed; int position; int moving; int leg; } trace[100]{};
  struct LegResult { int goal = -1, last = -1, samples = 0, tailSpread = -1; bool complete = false; } legs[2];
  unsigned traceCount = 0;
  if (yawTest) {
    yawResult = "preflight_refused";
    const auto& yaw = readings[0];
    const auto& pitch = readings[1];
    const bool safe = onVerified && !powerCutoff.done.load() && millis() - started < 1250 &&
      yaw.torque == 0 && pitch.torque == 0 && yaw.moving == 0 && pitch.moving == 0 &&
      yaw.minimum == 20 && yaw.maximum == 1003 && pitch.minimum == 20 && pitch.maximum == 1003 &&
      yaw.position >= 430 && yaw.position <= 480 && pitch.position >= 610 && pitch.position <= 650;
    if (safe) {
      // User confirmed visually centered at raw 434 as well as earlier 456.
      // Require within-window stability; do not explain away changing feedback.
      stableMin = stableMax = yaw.position;
      stableSamples = 1;
      for (int sample = 0; sample < 3 && !powerCutoff.done.load() && millis() - started < 1250; ++sample) {
        vTaskDelay(pdMS_TO_TICKS(25));
        const int value = servoBus.ReadPos(1);
        if (value < 430 || value > 480) break;
        stableMin = min(stableMin, value);
        stableMax = max(stableMax, value);
        yawStart = value;
        ++stableSamples;
      }
      yawGoal = yawStart + (yawDelta < 0 ? -8 : 8); // Fixed magnitude; no arbitrary host targets.
      if (stableSamples == 4 && stableMax - stableMin <= 3 && !powerCutoff.done.load() &&
          millis() - started < 1300 && yawStart >= 430 && yawStart <= 480) {
        // Replace any stale goal while torque is still off, then verify it.
        ++positionCommands;
        bool held = servoBus.WritePos(1, yawStart, 300, 0) == 1 && servoBus.getState() == 0 &&
          servoBus.readWord(1, SCSCL_GOAL_POSITION_L) == yawStart && servoBus.getState() == 0;
        if (held && !powerCutoff.done.load() && millis() - started < 1400) {
          bool armed = servoBus.EnableTorque(1, 1) == 1 && servoBus.getState() == 0 &&
            servoBus.readByte(1, SCSCL_TORQUE_ENABLE) == 1 && servoBus.getState() == 0;
          if (armed && !powerCutoff.done.load()) {
           for (int leg = 0; leg < (session ? 2 : 1); ++leg) {
            if (powerCutoff.done.load() || (session && millis() - started >= 3700)) break;
            yawGoal = session ? (leg == 0 ? yawStart - 8 : yawStart) : yawGoal;
            legs[leg].goal = yawGoal;
            const int rampStart = leg == 0 ? yawStart : yawEnd;
            int rampStep = 1;
            int sentGoal = ramp ? sessionWaypoint(rampStart, yawGoal, rampStep) : yawGoal;
            ++positionCommands;
            yawResult = "goal_write_failed";
            const int goalAck = servoBus.WritePos(1, sentGoal, ramp ? 20 : 300, 0);
            goalStatus = servoBus.getState();
            goalError = servoBus.getLastError();
            if (goalAck == 1 && goalStatus == 0 && goalError == 0) {
              goalReadback = servoBus.readWord(1, SCSCL_GOAL_POSITION_L);
            }
            if (goalAck == 1 && goalStatus == 0 && goalError == 0 && goalReadback == sentGoal &&
                servoBus.getState() == 0 && servoBus.getLastError() == 0) {
              yawResult = "feedback_outside_guard";
              const uint32_t moveStart = millis();
              int tail[5]{};
              int tailCount = 0;
              bool valid = true;
              while (!powerCutoff.done.load() && millis() - moveStart < (session ? 1000u : 400u) && millis() - started < (session ? 3700u : 1850u)) {
                // Small linear waypoints use the official 20ms WritePos time.
                // At most one update per loop; no catch-up burst on delays.
                if (ramp && rampStep < 8 && millis() - moveStart >= unsigned(rampStep * 40)) {
                  sentGoal = sessionWaypoint(rampStart, yawGoal, ++rampStep);
                  ++positionCommands;
                  const int ack = servoBus.WritePos(1, sentGoal, 20, 0);
                  goalStatus = servoBus.getState();
                  goalError = servoBus.getLastError();
                  if (ack != 1 || goalStatus != 0 || goalError != 0) {
                    valid = false; yawResult = "ramp_write_failed"; break;
                  }
                  goalReadback = servoBus.readWord(1, SCSCL_GOAL_POSITION_L);
                  if (goalReadback != sentGoal || servoBus.getState() != 0 || servoBus.getLastError() != 0) {
                    valid = false; yawResult = "ramp_readback_failed"; break;
                  }
                }
                yawEnd = servoBus.ReadPos(1);
                if (servoBus.getState() != 0 || servoBus.getLastError() != 0) {
                  valid = false; yawResult = "position_status_error"; break;
                }
                const int moving = servoBus.ReadMove(1);
                if (servoBus.getState() != 0 || servoBus.getLastError() != 0) {
                  valid = false; yawResult = "moving_status_error"; break;
                }
                if (traceCount < 100) trace[traceCount++] = {millis() - moveStart, yawEnd, moving, leg};
                const int lower = session ? yawStart - 11 : min(yawStart, yawGoal) - 3;
                const int upper = session ? yawStart + 3 : max(yawStart, yawGoal) + 3;
                if (yawEnd < lower || yawEnd > upper) { valid = false; yawResult = "feedback_outside_guard"; break; }
                if (moving < 0 || moving > 1) { valid = false; yawResult = "moving_feedback_missing"; break; }
                if (!session && abs(yawEnd - yawGoal) <= 2 && moving == 0) {
                  yawResult = "target_feedback_received";
                  break;
                }
                yawResult = "target_not_confirmed";
                tail[tailCount++ % 5] = yawEnd;
                legs[leg].last = yawEnd;
                ++legs[leg].samples;
                vTaskDelay(pdMS_TO_TICKS(20));
              }
              if (session) {
                int low = tail[0], high = tail[0];
                for (int i = 1; i < 5; ++i) { low = min(low, tail[i]); high = max(high, tail[i]); }
                legs[leg].tailSpread = high - low;
                legs[leg].complete = sessionLegComplete(valid && (!ramp || rampStep == 8), powerCutoff.done.load(), tailCount,
                  millis() - moveStart, high - low, traceCount ? trace[traceCount - 1].moving : -1,
                  leg, yawStart, yawEnd);
                if (!legs[leg].complete) { if (valid) yawResult = "session_unsettled_or_deadline"; break; }
                yawResult = leg == 1 ? "session_measured" : "session_first_leg_measured";
              }
            }
            if (session && !legs[leg].complete) break;
           }
          } else yawResult = "torque_enable_unverified";
        } else yawResult = "hold_goal_unverified_or_deadline";
      } else yawResult = "position_changed_or_outside_guard";
    }
    servoBus.EnableTorque(0xfe, 0);
  }
  // The task stays alive until release, even if its deadline already fired.
  xTaskNotifyGive(cutoff);
  while (!powerCutoff.done.load()) vTaskDelay(1);
  const EnableSnapshot after = readEnable(device);
  bool offVerified = powerCutoff.written.load() && after.modeError == ESP_OK &&
    (after.mode & 1) && after.latchError == ESP_OK && !(after.latch & 1);
  i2c_master_bus_rm_device(device);
  powerCutoff.release.store(true);
  vTaskDelay(pdMS_TO_TICKS(250));
  const int offVoltage[] = {servoBus.ReadVoltage(1), servoBus.ReadVoltage(2)};
  // No USB output while power is enabled: a stalled host cannot delay cutoff.
  if (yawTest) Serial.printf("SBPD {\"phase\":\"goal_confirmation\",\"readback\":%d,\"write_status\":%d,\"write_error\":%d}\n",
                            goalReadback, goalStatus, goalError);
  for (unsigned i = 0; i < traceCount; ++i)
    Serial.printf("SBPD {\"phase\":\"yaw_trace\",\"elapsed_ms\":%lu,\"position\":%d,\"moving\":%d,\"leg\":%d}\n",
                  (unsigned long)trace[i].elapsed, trace[i].position, trace[i].moving, trace[i].leg);
  if (session) for (int leg = 0; leg < 2; ++leg)
    Serial.printf("SBLG {\"leg\":%d,\"goal\":%d,\"last\":%d,\"samples\":%d,\"tail_spread\":%d,\"complete\":%s}\n",
      leg, legs[leg].goal, legs[leg].last, legs[leg].samples, legs[leg].tailSpread, legs[leg].complete ? "true" : "false");
  printEnable("immediate", immediate);
  printEnable("settled", settled);
  printEnable("after_cutoff", after);
  printReadiness(readings, offVoltage);
  if (yawTest) Serial.printf("SBMV {\"result\":\"%s\",\"start\":%d,\"goal\":%d,\"last_position\":%d,\"stable_samples\":%d,\"stable_min\":%d,\"stable_max\":%d}\n",
                            yawResult, yawStart, yawGoal, yawEnd, stableSamples, stableMin, stableMax);
  Serial.printf("SBPW {\"power_write_ack\":%s,\"enable_latch_high_verified\":%s,\"disable_latch_low_verified\":%s,\"rail_off_verified\":false,\"elapsed_ms\":%lu,\"position_commands\":%d}\n",
                enabled ? "true" : "false", onVerified ? "true" : "false", offVerified ? "true" : "false", (unsigned long)(millis() - started), positionCommands);
}

// Supervised bounded motion on ONE servo, requested explicitly by the user
// 2026-09-15: a plan of absolute goals (or goals relative to the measured start)
// visited in order with a pause at each. The other servo stays torque-off.
// Every waypoint write is verified; feedback must stay inside the plan's
// envelope; a stall (goal far away, feedback not advancing) aborts with
// torque-off; and the independent cutoff removes motor power at the plan's
// deadline regardless of what this task does. No EEPROM/NVS writes.
constexpr int kYawCenter = 460;           // BSP defaultZeroPos for ID 1.
constexpr int kSweepHalfTravel = 288;     // 90 degrees: 900 tenths * 16 / 50.
constexpr int kSweepStep = 8;             // raw steps per waypoint (~2.5 deg).
constexpr uint32_t kSweepWaypointMs = 40; // ~58 deg/s; well under servo max.
constexpr uint32_t kSweepPauseMs = 1000;
constexpr uint32_t kSweepSettleMs = 1500; // max wait for a leg to arrive.
constexpr int kSweepEnvelopeMargin = 16;
constexpr int kSweepStallDistance = 16;   // goal further than this and...
constexpr uint32_t kSweepStallMs = 600;   // ...no 3-step progress for this long.

struct MotionPlan {
  const char* label;
  int servoId;                 // 1 yaw, 2 pitch. The other is never driven.
  int legCount;                // <= 4
  int goals[4];                // absolute raw, or offsets when relative
  const char* names[4];
  bool relative;               // goals are offsets from the measured start
  int startLow, startHigh;     // refuse unless the driven servo starts here
  int otherLow, otherHigh;     // sanity range for the idle servo
  uint32_t cutoffMs;
};

// Center, 90 degrees robot-left (-raw), 90 degrees robot-right (+raw), center.
const MotionPlan kYawSweepPlan = {"yaw_sweep", 1, 4,
  {kYawCenter, kYawCenter - kSweepHalfTravel, kYawCenter + kSweepHalfTravel, kYawCenter},
  {"center", "robot_left", "robot_right", "center"}, false, 300, 620, 560, 700, 20000};
const MotionPlan kYawCenterPlan = {"yaw_center", 1, 1, {kYawCenter, 0, 0, 0},
  {"center", "", "", ""}, false, 300, 620, 560, 700, 8000};
// First pitch motion: +16 raw (5 degrees) from rest and back. The BSP maps
// pitch angle 0..90 degrees onto raw 620..908, so +raw is the only direction
// inside the official range from the rest position; -raw is never commanded.
// Physical direction (nod up or down) is for the user to observe.
const MotionPlan kPitchNudgePlan = {"pitch_nudge", 2, 2, {16, 0, 0, 0},
  {"pitch_plus16", "pitch_return", "", ""}, true, 600, 650, 300, 620, 8000};

void runBoundedMotion(const MotionPlan& plan) {
  if (disableOnlyLatched || powerWindowUsed || streamEnabled.load()) {
    Serial.println("SBPW {\"error\":\"requires_stopped_stream_and_unused_boot\"}");
    return;
  }
  powerWindowUsed = true;
  i2c_master_dev_handle_t device = nullptr;
  uint8_t off = 0;
  TaskHandle_t cutoff = nullptr;
  if (!openPowerWindow(device, off, plan.cutoffMs, cutoff)) return;
  servoBus.EnableTorque(0xfe, 0);
  const uint32_t started = millis();
  bool enabled = writeBase(device, 0x05, off | 1u);
  const EnableSnapshot immediate = readEnable(device);
  const uint32_t settleStarted = millis();
  while (enabled && !powerCutoff.done.load() && millis() - settleStarted < 200) {
    servoBus.EnableTorque(0xfe, 0);
    vTaskDelay(pdMS_TO_TICKS(20));
  }
  const EnableSnapshot settled = readEnable(device);
  const bool onVerified = enabled && !powerCutoff.done.load() && settled.outputHigh();
  ServoReading readings[2];
  if (onVerified) readStartupReadiness(readings, started);

  const int id = plan.servoId;
  const auto& driven = readings[id - 1];
  const auto& idle = readings[2 - id];
  int goals[4]{};
  int envelopeLow = 0, envelopeHigh = 0;
  struct LegSummary { int goal = -1, final = -1, error = 0; uint32_t durationMs = 0; bool arrived = false; } legs[4];
  struct TracePoint { uint32_t elapsed; int goal; int position; int moving; int leg; };
  static TracePoint trace[400];
  unsigned traceCount = 0;
  const char* result = "preflight_refused";
  int posStart = -1, posEnd = -1, positionCommands = 0, legsDone = 0;

  const bool safe = onVerified && !powerCutoff.done.load() && millis() - started < 1300 &&
    driven.torque == 0 && idle.torque == 0 && driven.moving == 0 && idle.moving == 0 &&
    driven.minimum == 20 && driven.maximum == 1003 && idle.minimum == 20 && idle.maximum == 1003 &&
    driven.position >= plan.startLow && driven.position <= plan.startHigh &&
    idle.position >= plan.otherLow && idle.position <= plan.otherHigh;
  if (safe) {
    posStart = posEnd = driven.position;
    envelopeLow = envelopeHigh = posStart;
    for (int leg = 0; leg < plan.legCount; ++leg) {
      goals[leg] = plan.relative ? posStart + plan.goals[leg] : plan.goals[leg];
      envelopeLow = min(envelopeLow, goals[leg]);
      envelopeHigh = max(envelopeHigh, goals[leg]);
    }
    envelopeLow -= kSweepEnvelopeMargin;
    envelopeHigh += kSweepEnvelopeMargin;
    ++positionCommands;
    const bool held = servoBus.WritePos(id, posStart, kSweepWaypointMs, 0) == 1 && servoBus.getState() == 0 &&
      servoBus.readWord(id, SCSCL_GOAL_POSITION_L) == posStart && servoBus.getState() == 0;
    result = "hold_goal_unverified";
    if (held && !powerCutoff.done.load()) {
      const bool armed = servoBus.EnableTorque(id, 1) == 1 && servoBus.getState() == 0 &&
        servoBus.readByte(id, SCSCL_TORQUE_ENABLE) == 1 && servoBus.getState() == 0;
      result = "torque_enable_unverified";
      if (armed && !powerCutoff.done.load()) {
        result = "sweep_complete";
        for (int leg = 0; leg < plan.legCount && strcmp(result, "sweep_complete") == 0; ++leg) {
          const int goal = goals[leg];
          legs[leg].goal = goal;
          int sent = posEnd;
          const int direction = goal >= sent ? 1 : -1;
          bool finalSent = sent == goal;
          const uint32_t legStart = millis();
          uint32_t nextWaypointAt = legStart;
          uint32_t finalSentAt = finalSent ? legStart : 0;
          uint32_t lastProgressAt = legStart;
          int lastProgressPos = posEnd;
          uint32_t arrivedAt = 0;
          for (;;) {
            if (powerCutoff.done.load()) { result = "cutoff_before_completion"; break; }
            const uint32_t now = millis();
            // Waypoints advance on schedule; a late loop sends one, not a burst.
            if (!finalSent && now >= nextWaypointAt) {
              sent += direction * kSweepStep;
              if ((direction > 0 && sent >= goal) || (direction < 0 && sent <= goal)) { sent = goal; finalSent = true; }
              ++positionCommands;
              const int ack = servoBus.WritePos(id, sent, kSweepWaypointMs, 0);
              if (ack != 1 || servoBus.getState() != 0 || servoBus.getLastError() != 0) { result = "goal_write_failed"; break; }
              if (servoBus.readWord(id, SCSCL_GOAL_POSITION_L) != sent || servoBus.getState() != 0) { result = "goal_readback_failed"; break; }
              nextWaypointAt += kSweepWaypointMs;
              if (finalSent) finalSentAt = now;
            }
            posEnd = servoBus.ReadPos(id);
            if (servoBus.getState() != 0 || servoBus.getLastError() != 0 || posEnd < 0) { result = "position_status_error"; break; }
            const int moving = servoBus.ReadMove(id);
            if (servoBus.getState() != 0 || servoBus.getLastError() != 0 || moving < 0 || moving > 1) { result = "moving_status_error"; break; }
            if (traceCount < 400 && (traceCount == 0 || now - trace[traceCount - 1].elapsed >= 40))
              trace[traceCount++] = {now - started, sent, posEnd, moving, leg};
            if (posEnd < envelopeLow || posEnd > envelopeHigh) { result = "feedback_outside_envelope"; break; }
            if (abs(posEnd - lastProgressPos) >= 3) { lastProgressPos = posEnd; lastProgressAt = now; }
            if (abs(sent - posEnd) > kSweepStallDistance && now - lastProgressAt > kSweepStallMs) { result = "stall_detected"; break; }
            if (finalSent) {
              if (!arrivedAt && abs(posEnd - goal) <= 6 && moving == 0) { arrivedAt = now; legs[leg].arrived = true; }
              // Both intervals count from a timestamp that is never in the
              // future; the first run (2026-09-15) subtracted the next scheduled
              // waypoint time, wrapped, and ended every leg early.
              const bool settledNow = arrivedAt && now - arrivedAt >= kSweepPauseMs;
              const bool gaveUp = !arrivedAt && now - finalSentAt >= kSweepSettleMs + kSweepPauseMs;
              if (settledNow || gaveUp) break;
            }
            vTaskDelay(pdMS_TO_TICKS(10));
          }
          legs[leg].final = posEnd;
          legs[leg].error = posEnd - goal;
          legs[leg].durationMs = millis() - legStart;
          if (strcmp(result, "sweep_complete") == 0) ++legsDone;
        }
      }
    }
  }
  servoBus.EnableTorque(0xfe, 0);
  xTaskNotifyGive(cutoff);
  while (!powerCutoff.done.load()) vTaskDelay(1);
  servoBus.EnableTorque(0xfe, 0);
  const EnableSnapshot after = readEnable(device);
  const bool offVerified = powerCutoff.written.load() && after.modeError == ESP_OK &&
    (after.mode & 1) && after.latchError == ESP_OK && !(after.latch & 1);
  i2c_master_bus_rm_device(device);
  powerCutoff.release.store(true);
  vTaskDelay(pdMS_TO_TICKS(250));
  const int offVoltage[] = {servoBus.ReadVoltage(1), servoBus.ReadVoltage(2)};
  // No USB output while power is enabled; everything above was buffered.
  for (unsigned i = 0; i < traceCount; ++i)
    Serial.printf("SBPD {\"phase\":\"sweep_trace\",\"elapsed_ms\":%lu,\"goal\":%d,\"position\":%d,\"moving\":%d,\"leg\":%d}\n",
                  (unsigned long)trace[i].elapsed, trace[i].goal, trace[i].position, trace[i].moving, trace[i].leg);
  for (int leg = 0; leg < plan.legCount; ++leg)
    Serial.printf("SBLG {\"leg\":%d,\"name\":\"%s\",\"goal\":%d,\"final\":%d,\"error\":%d,\"duration_ms\":%lu,\"arrived\":%s}\n",
                  leg, plan.names[leg], legs[leg].goal, legs[leg].final, legs[leg].error,
                  (unsigned long)legs[leg].durationMs, legs[leg].arrived ? "true" : "false");
  printEnable("immediate", immediate);
  printEnable("settled", settled);
  printEnable("after_cutoff", after);
  printReadiness(readings, offVoltage);
  Serial.printf("SBMV {\"result\":\"%s\",\"plan\":\"%s\",\"servo\":%d,\"start\":%d,\"last_position\":%d,\"legs_done\":%d,\"legs_planned\":%d,\"envelope_low\":%d,\"envelope_high\":%d}\n",
                result, plan.label, id, posStart, posEnd, legsDone, plan.legCount, envelopeLow, envelopeHigh);
  Serial.printf("SBPW {\"power_write_ack\":%s,\"enable_latch_high_verified\":%s,\"disable_latch_low_verified\":%s,\"rail_off_verified\":false,\"elapsed_ms\":%lu,\"position_commands\":%d}\n",
                enabled ? "true" : "false", onVerified ? "true" : "false", offVerified ? "true" : "false", (unsigned long)(millis() - started), positionCommands);
}

void testServoDisable() {
  if (disableOnlyLatched || streamEnabled.load()) {
    Serial.println("SBOF {\"error\":\"requires_stopped_stream_and_unused_disable_test\"}");
    return;
  }
  disableOnlyLatched = true;
  i2c_master_bus_handle_t master = nullptr;
  i2c_master_dev_handle_t device = nullptr;
  i2c_device_config_t config{};
  config.dev_addr_length = I2C_ADDR_BIT_LEN_7;
  config.device_address = 0x6f;
  config.scl_speed_hz = 100000;
  esp_err_t status = i2c_master_get_bus_handle(kSccbPort, &master);
  if (status == ESP_OK) status = i2c_master_bus_add_device(master, &config, &device);
  if (status != ESP_OK) {
    Serial.printf("SBOF {\"error\":\"base_unavailable\",\"i2c_error\":%d}\n", status);
    return;
  }
  const EnableSnapshot before = readEnable(device);
  // Never rewrite direction, pulls, or unrelated output bits. No torque writes.
  if (before.modeError != ESP_OK || before.latchError != ESP_OK || !(before.mode & 1)) {
    i2c_master_bus_rm_device(device);
    printEnable("before_disable", before);
    Serial.println("SBOF {\"error\":\"starting_output_state_unverified\"}");
    return;
  }
  int beforeVoltage[2] = {-1, -1}, afterVoltage[2] = {-1, -1};
  const bool uartReady = prepareServoBus();
  if (uartReady) for (int id = 1; id <= 2; ++id) beforeVoltage[id - 1] = servoBus.ReadVoltage(id);
  const bool written = writeBase(device, 0x05, before.latch & ~1u);
  vTaskDelay(pdMS_TO_TICKS(250));
  const EnableSnapshot after = readEnable(device);
  if (uartReady) for (int id = 1; id <= 2; ++id) afterVoltage[id - 1] = servoBus.ReadVoltage(id);
  i2c_master_bus_rm_device(device);
  const bool latchLow = written && after.modeError == ESP_OK && (after.mode & 1) &&
    after.latchError == ESP_OK && !(after.latch & 1);
  // Report only after the off attempt; host backpressure cannot delay the write.
  printEnable("before_disable", before);
  printEnable("after_disable", after);
  for (int id = 1; id <= 2; ++id)
    Serial.printf("SBPD {\"phase\":\"disable_voltage\",\"id\":%d,\"before_raw\":%d,\"after_raw\":%d}\n",
      id, beforeVoltage[id - 1], afterVoltage[id - 1]);
  Serial.printf("SBOF {\"off_write_ack\":%s,\"output_latch_low_verified\":%s,\"rail_off_verified\":false,\"reenable_blocked_until_reboot\":true,\"position_commands\":0}\n",
    written ? "true" : "false", latchLow ? "true" : "false");
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
  uint8_t registers[18]{}; // 0x02..0x13 includes VM pulls and drive mode.
  const uint8_t startRegister = 0x02; // BSP: version, direction, output, input.
  if (status == ESP_OK) status = readBaseRegisters(device, startRegister, registers, sizeof(registers));
  if (device) i2c_master_bus_rm_device(device);
  if (status == ESP_OK) {
    Serial.printf("SBSC {\"base\":true,\"version\":%u,\"vm_output_mode\":%u,\"vm_output_latch\":%u,\"vm_input_level\":%u,\"read_only\":true}\n",
                  registers[0], registers[1] & 1, registers[3] & 1, registers[5] & 1);
    Serial.printf("SBPD {\"phase\":\"read_only_config\",\"vm_pull_up\":%u,\"vm_pull_down\":%u,\"vm_open_drain\":%u}\n",
                  registers[7] & 1, registers[9] & 1, registers[17] & 1);
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
    // Raw telemetry only: do not infer volts or authorize motion from this byte.
    int voltageRaw = bus.ReadVoltage(id);
    Serial.printf("SBPD {\"phase\":\"read_only_voltage\",\"id\":%d,\"voltage_raw\":%d}\n", id, voltageRaw);
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
    if (powerOffRequested.exchange(false)) testServoDisable();
    if (yawTestRequested.exchange(false)) testServoPower(true);
    if (yawBackRequested.exchange(false)) testServoPower(true, -8);
    if (yawSessionRequested.exchange(false)) testServoPower(true, -8, true);
    if (yawRampRequested.exchange(false)) testServoPower(true, -8, true, true);
    if (yawSweepRequested.exchange(false)) runBoundedMotion(kYawSweepPlan);
    if (yawCenterRequested.exchange(false)) runBoundedMotion(kYawCenterPlan);
    if (pitchNudgeRequested.exchange(false)) runBoundedMotion(kPitchNudgePlan);
    if (rebootRequested.exchange(false)) {
      // Software restart so a fresh once-per-boot power window is available
      // without a physical RST. Motor power is already off (latch verified)
      // or was never enabled this boot.
      Serial.println("SBRB {\"rebooting\":true}");
      Serial.flush();
      vTaskDelay(pdMS_TO_TICKS(100));
      esp_restart();
    }
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
