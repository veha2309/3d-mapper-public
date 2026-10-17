package com.vicentric.three_d_mapper

/** Keep a successful fallback view available for confirmation, while exploring others. */
class FallbackScheduler {
    private var preferred: String? = null
    private var cursor = 0
    fun remember(id: String) { preferred = id }
    fun reset() { preferred = null; cursor = 0 }
    fun select(all: List<String>, ranked: List<String>): List<String> {
        if (all.isEmpty()) return emptyList()
        val sticky = preferred?.takeIf { it in all }
        val top = ranked.filter { it in all }.take(if (sticky == null) 2 else 1)
        val rotating = all[cursor % all.size]
        cursor = (cursor + 1) % all.size
        return (listOfNotNull(sticky) + top + rotating).distinct().take(3)
    }
}
