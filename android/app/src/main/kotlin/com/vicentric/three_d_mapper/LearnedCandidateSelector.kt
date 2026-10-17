package com.vicentric.three_d_mapper

/** Cheap retrieval chooses distinct identities; only neural geometry can confirm. */
class LearnedCandidateSelector(private val limit: Int = 2) {
    init { require(limit >= 2) }
    data class Candidate(val id: String, val identity: String, val inliers: Int, val ratio: Double, val matches: Int)
    fun select(candidates: List<Candidate>): List<String> = candidates
        .sortedWith(compareByDescending<Candidate> { it.inliers * it.ratio }.thenByDescending { it.matches })
        .distinctBy { it.identity }.take(limit).map { it.id }
}
