#include "../firmware/camera_stream/session_guard.h"
#include <cassert>

int main() {
  for (int start = 430; start <= 480; ++start) {
    for (int goal = start - 8; goal <= start + 8; ++goal) {
      int previous = start;
      for (int step = 1; step <= 8; ++step) {
        int value = sessionWaypoint(start, goal, step);
        assert(goal >= start ? (value >= previous && value <= goal) : (value <= previous && value >= goal));
        previous = value;
      }
      assert(previous == goal);
    }
  }
  assert(sessionLegComplete(true, false, 37, 1000, 2, 0, 0, 477, 473));
  assert(sessionLegComplete(true, false, 37, 1000, 2, 0, 1, 477, 476));
  assert(!sessionLegComplete(false, false, 37, 1000, 2, 0, 0, 477, 473));
  assert(!sessionLegComplete(true, true, 37, 1000, 2, 0, 0, 477, 473));
  assert(!sessionLegComplete(true, false, 4, 1000, 2, 0, 0, 477, 473));
  assert(!sessionLegComplete(true, false, 37, 999, 2, 0, 0, 477, 473));
  assert(!sessionLegComplete(true, false, 37, 1000, 3, 0, 0, 477, 473));
  assert(!sessionLegComplete(true, false, 37, 1000, 2, 1, 0, 477, 473));
  assert(!sessionLegComplete(true, false, 37, 1000, 2, -1, 0, 477, 473));
  assert(!sessionLegComplete(true, false, 37, 1000, 2, 0, 0, 477, 477));
  assert(!sessionLegComplete(true, false, 37, 1000, 2, 0, 0, 477, 479));
}
