package com.vicentric.three_d_mapper

fun referenceIdentity(entry: Map<*, *>): String = (entry["feature_id"] as? String)?.let { "map:$it" }
    ?: "label:${entry["identity_id"] ?: entry["id"]}"
