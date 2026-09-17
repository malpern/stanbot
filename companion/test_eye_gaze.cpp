#include "../firmware/camera_stream/eye_gaze.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>

using stanbot::gazeForImage;
using stanbot::parseGazeLine;

int main() {
  // A face on the right of the image is on the viewer's left of the screen.
  assert(gazeForImage(0.5f, 0.0f).x == -0.5f);
  assert(gazeForImage(-1.0f, 0.0f).x == 1.0f);
  // Up is up on both.
  assert(gazeForImage(0.0f, -0.8f).y == -0.8f);
  assert(gazeForImage(0.0f, 0.0f).x == 0.0f && gazeForImage(0.0f, 0.0f).y == 0.0f);
  // Clamped.
  assert(gazeForImage(-3.0f, 7.0f).x == 1.0f && gazeForImage(-3.0f, 7.0f).y == 1.0f);

  float x = 9, y = 9;
  assert(parseGazeLine("0.250,-0.500", x, y) && x == 0.25f && y == -0.5f);
  assert(parseGazeLine("-1,1", x, y));
  for (const char* bad : {"", "0.2", "1.1,0", "0,-1.01", "nan,0", "0,0,0,0", "0.1,0.2x", "a,b"}) {
    assert(!parseGazeLine(bad, x, y));
  }
  assert(!parseGazeLine(nullptr, x, y));
  // The engaged flag: optional, 0 or 1 only.
  bool engaged = true;
  assert(parseGazeLine("0.1,0.2", x, y, engaged) && !engaged);
  assert(parseGazeLine("0.1,0.2,1", x, y, engaged) && engaged);
  assert(parseGazeLine("0.1,0.2,0", x, y, engaged) && !engaged);
  for (const char* bad : {"0.1,0.2,2", "0.1,0.2,1x", "0.1,0.2,", "0.1,0.2,1,1", "0.1,0.2,-1"}) {
    assert(!parseGazeLine(bad, x, y, engaged));
  }
  std::printf("eye gaze: all tests passed\n");
}
