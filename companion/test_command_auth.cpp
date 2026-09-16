// c++ -std=c++17 companion/test_command_auth.cpp -o /tmp/test_command_auth && /tmp/test_command_auth
#include "../firmware/camera_stream/command_auth.h"
#include <CommonCrypto/CommonHMAC.h>
#include <cassert>
#include <cstdio>
#include <string>

using stanbot::CommandAuth;

static bool hmac(const uint8_t* key, size_t keyLength, const uint8_t* message, size_t messageLength, uint8_t out[32]) {
  CCHmac(kCCHmacAlgSHA256, key, keyLength, message, messageLength, out);
  return true;
}

static std::string macFor(const char* command, const char* nonce, const char* key) {
  const std::string message = std::string(command) + ":" + nonce;
  uint8_t mac[32];
  hmac(reinterpret_cast<const uint8_t*>(key), std::strlen(key),
       reinterpret_cast<const uint8_t*>(message.data()), message.size(), mac);
  char hex[65];
  for (int i = 0; i < 32; ++i) std::snprintf(hex + 2 * i, 3, "%02x", mac[i]);
  return hex;
}

int main() {
  const uint8_t random[16] = {0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                              0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
  const char* key = "correct horse battery staple";

  // The shared test vector, computed independently with Python's hmac module;
  // the Swift app's tests check the same value.
  assert(macFor("FOLLOW", "00112233445566778899aabbccddeeff", key) ==
         "ddefdb5a5ae93875b5911d6e3dd6bff073c70007431ff2d71f8b84b8ece41f76");

  CommandAuth auth(hmac);
  // No challenge yet.
  assert(auth.verify("FOLLOW", macFor("FOLLOW", "", key).c_str(), key, 0) == CommandAuth::Result::NoChallenge);

  const std::string nonce = auth.issue(random, 1000);
  assert(nonce == "00112233445566778899aabbccddeeff");
  assert(auth.verify("FOLLOW", "ddefdb5a5ae93875b5911d6e3dd6bff073c70007431ff2d71f8b84b8ece41f76", key, 2000) ==
         CommandAuth::Result::Ok);
  // Replay of the same, correct exchange.
  assert(auth.verify("FOLLOW", "ddefdb5a5ae93875b5911d6e3dd6bff073c70007431ff2d71f8b84b8ece41f76", key, 2001) ==
         CommandAuth::Result::NoChallenge);

  // Uppercase hex is accepted.
  auth.issue(random, 3000);
  assert(auth.verify("FOLLOW", "DDEFDB5A5AE93875B5911D6E3DD6BFF073C70007431FF2D71F8B84B8ECE41F76", key, 3001) ==
         CommandAuth::Result::Ok);

  // A wrong passphrase, and the challenge is gone afterwards even for the right one.
  auth.issue(random, 4000);
  assert(auth.verify("FOLLOW", macFor("FOLLOW", nonce.c_str(), "wrong").c_str(), key, 4001) == CommandAuth::Result::BadMac);
  assert(auth.verify("FOLLOW", macFor("FOLLOW", nonce.c_str(), key).c_str(), key, 4002) == CommandAuth::Result::NoChallenge);

  // A MAC for one command does not authorize another.
  auth.issue(random, 5000);
  assert(auth.verify("REBOOT", macFor("FOLLOW", nonce.c_str(), key).c_str(), key, 5001) == CommandAuth::Result::BadMac);

  // Expiry, including across millis() wrap.
  auth.issue(random, 6000);
  assert(auth.verify("REBOOT", macFor("REBOOT", nonce.c_str(), key).c_str(), key, 6000 + 30001) == CommandAuth::Result::Expired);
  auth.issue(random, 4294967000u);
  assert(auth.verify("REBOOT", macFor("REBOOT", nonce.c_str(), key).c_str(), key, 500) == CommandAuth::Result::Ok);

  // No passphrase on the robot means nothing can be authorized.
  auth.issue(random, 7000);
  assert(auth.verify("FOLLOW", macFor("FOLLOW", nonce.c_str(), "").c_str(), "", 7001) == CommandAuth::Result::NoKey);

  // Only FOLLOW and REBOOT; malformed MACs are refused.
  auth.issue(random, 8000);
  assert(auth.verify("YAWSWEEP", macFor("YAWSWEEP", nonce.c_str(), key).c_str(), key, 8001) == CommandAuth::Result::UnknownCommand);
  auth.issue(random, 9000);
  assert(auth.verify("FOLLOW", "abc", key, 9001) == CommandAuth::Result::Malformed);

  std::puts("command auth: all checks passed");
}
