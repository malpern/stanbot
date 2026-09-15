#pragma once

inline int sessionWaypoint(int start, int goal, int step) {
  return start + (goal - start) * step / 8;
}

// Pure decision rule, shared by firmware and native boundary tests.
// Position guard checks occur on every sample before this settling gate.
inline bool sessionLegComplete(bool valid, bool cutoff, int samples,
                               unsigned elapsed, int spread, int moving,
                               int leg, int start, int last) {
  return valid && !cutoff && samples >= 5 && elapsed >= 1000 &&
         spread >= 0 && spread <= 2 && moving == 0 &&
         (leg != 0 || last <= start - 2);
}
