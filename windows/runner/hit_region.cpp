#include "hit_region.h"

#include <algorithm>

HitRegion& HitRegion::Instance() {
  static HitRegion instance;
  return instance;
}

void HitRegion::SetRects(std::vector<HitRect> rects) {
  std::lock_guard<std::mutex> lock(mutex_);
  rects_ = std::move(rects);
}

void HitRegion::SetDragging(bool on) {
  std::lock_guard<std::mutex> lock(mutex_);
  dragging_ = on;
}

bool HitRegion::dragging() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return dragging_;
}

bool HitRegion::Contains(double px, double py) const {
  std::lock_guard<std::mutex> lock(mutex_);
  for (const auto& rect : rects_) {
    const double lx = px - rect.x;
    const double ly = py - rect.y;
    if (lx < 0 || ly < 0 || lx > rect.w || ly > rect.h) {
      continue;
    }
    // 与 lib/core/hit.dart insideRoundedRect 保持逐字一致
    const double r = std::min({rect.radius, rect.w / 2, rect.h / 2});
    const double dx = std::max({r - lx, 0.0, lx - (rect.w - r)});
    const double dy = std::max({r - ly, 0.0, ly - (rect.h - r)});
    if (dx * dx + dy * dy <= r * r + 1) {
      return true;
    }
  }
  return false;
}
