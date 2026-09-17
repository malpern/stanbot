#pragma once
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstring>

namespace stanbot {

// Authorizes motion-related commands arriving over Wi-Fi, which the network
// allowlist otherwise refuses. Challenge-response, so the passphrase never
// crosses the network and a captured exchange cannot be replayed:
//
//   viewer -> A,?                      robot -> SBAC {"nonce":"<32 hex>"}
//   viewer -> A,<COMMAND>,<64 hex>     robot -> SBAU {"command":...,"ok":...}
//
// where the hex is HMAC-SHA256(key = OTA passphrase, message = "COMMAND:nonce").
// A challenge is consumed by the first attempt against it, right or wrong, and
// expires after kLifetimeMs, so each guess costs a round trip. Pure: the HMAC is
// injected (mbedtls on the robot, CommonCrypto in companion/test_command_auth.cpp).
using HmacSha256 = bool (*)(const uint8_t* key, size_t keyLength, const uint8_t* message,
                            size_t messageLength, uint8_t out[32]);

class CommandAuth {
 public:
  enum class Result { Ok, NoChallenge, Expired, BadMac, NoKey, UnknownCommand, Malformed };
  static constexpr uint32_t kLifetimeMs = 30000;

  explicit CommandAuth(HmacSha256 hmac) : hmac_(hmac) {}

  // Issues a fresh challenge from 16 random bytes, replacing any outstanding one.
  const char* issue(const uint8_t random[16], uint32_t nowMs) {
    for (int i = 0; i < 16; ++i) std::snprintf(nonce_ + 2 * i, 3, "%02x", random[i]);
    live_ = true;
    issuedMs_ = nowMs;
    return nonce_;
  }

  Result verify(const char* command, const char* macHex, const char* key, uint32_t nowMs) {
    const bool live = live_;
    live_ = false;                                    // consumed by any attempt
    if (!live) return Result::NoChallenge;
    if (nowMs - issuedMs_ > kLifetimeMs) return Result::Expired;
    if (key == nullptr || key[0] == '\0') return Result::NoKey;
    if (!allowed(command)) return Result::UnknownCommand;
    if (macHex == nullptr || std::strlen(macHex) != 64) return Result::Malformed;
    char message[64];
    const int length = std::snprintf(message, sizeof message, "%s:%s", command, nonce_);
    if (length <= 0 || length >= static_cast<int>(sizeof message)) return Result::Malformed;
    uint8_t mac[32];
    if (!hmac_(reinterpret_cast<const uint8_t*>(key), std::strlen(key),
               reinterpret_cast<const uint8_t*>(message), static_cast<size_t>(length), mac)) {
      return Result::BadMac;
    }
    char expected[65];
    for (int i = 0; i < 32; ++i) std::snprintf(expected + 2 * i, 3, "%02x", mac[i]);
    unsigned difference = 0;                          // constant time over all 64 characters
    for (int i = 0; i < 64; ++i) difference |= static_cast<unsigned>(expected[i] ^ lower(macHex[i]));
    return difference == 0 ? Result::Ok : Result::BadMac;
  }

  static const char* name(Result result) {
    switch (result) {
      case Result::Ok: return "ok";
      case Result::NoChallenge: return "no_challenge";
      case Result::Expired: return "challenge_expired";
      case Result::BadMac: return "bad_mac";
      case Result::NoKey: return "no_passphrase_stored";
      case Result::UnknownCommand: return "unknown_command";
      case Result::Malformed: return "malformed";
    }
    return "unknown";
  }

  // Only these may be authorized. Stopping needs no authorization at all.
  static bool allowed(const char* command) {
    return command != nullptr && (std::strcmp(command, "FOLLOW") == 0 || std::strcmp(command, "REBOOT") == 0 ||
                                 std::strcmp(command, "OFF") == 0);
  }

 private:
  static char lower(char c) { return (c >= 'A' && c <= 'F') ? static_cast<char>(c - 'A' + 'a') : c; }

  HmacSha256 hmac_;
  char nonce_[33] = {};
  bool live_ = false;
  uint32_t issuedMs_ = 0;
};

}  // namespace stanbot
