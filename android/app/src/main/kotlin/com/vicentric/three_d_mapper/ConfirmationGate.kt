package com.vicentric.three_d_mapper

/** Never carry a confirmed identity through a blank, ambiguous, or stale frame. */
class ConfirmationGate {
    private var identity: String? = null
    private var previousTime = 0L
    var streak = 0
        private set
    fun reset() { identity = null; previousTime = 0; streak = 0 }
    fun update(candidate: String?, now: Long): Boolean {
        if (candidate == null) { reset(); return false }
        streak = if (identity == candidate && now - previousTime in 1..1800) streak + 1 else 1
        identity = candidate; previousTime = now
        return streak >= 3
    }
}
