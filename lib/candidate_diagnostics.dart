import 'package:flutter/material.dart';

class CandidateDiagnostics extends StatelessWidget {
  const CandidateDiagnostics({super.key, required this.candidates});
  final List<dynamic> candidates;
  @override
  Widget build(BuildContext context) {
    final groups = <String, List<Map>>{};
    for (final value in candidates) {
      if (value is Map) {
        final key =
            '${value['identity'] ?? value['label_id'] ?? value['name']}';
        groups.putIfAbsent(key, () => []).add(value);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'All landmark candidates (${groups.length} landmarks, ${candidates.length} reference attempts)',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Text(
          candidates.any(
                (c) => c is Map && '${c['matcher']}'.startsWith('ALIKED'),
              )
              ? 'All views are ranked by descriptor geometry. LightGlue checks up to two distinct landmarks. Retrieval-only rows are not confirmed recognition.'
              : 'Candidate rows are diagnostic evidence, not confirmed recognitions. ORB covers all loaded views; SIFT is a bounded fallback.',
        ),
        for (final group in groups.entries)
          ExpansionTile(
            key: PageStorageKey(group.key),
            tilePadding: EdgeInsets.zero,
            title: Text('${group.value.first['name'] ?? group.key}'),
            subtitle: Text(
              '${group.value.length} attempts · ${group.value.any((c) => c['reason'] == 'verified') ? 'geometric evidence found' : 'not verified'}',
            ),
            children: [
              for (final c in group.value)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '${c['source'] ?? 'reference'} · ${c['matcher'] ?? 'not analyzed'}\n'
                      'Reference ${c['reference_id'] ?? c['label_id'] ?? '—'}\n'
                      'Reason: ${c['reason']} · keypoints ${c['reference_keypoints'] ?? '—'}\n'
                      '${c['good_matches'] ?? 0} good matches · ${c['inliers'] ?? 0} inliers · ratio ${c['inlier_ratio'] ?? '—'}\n'
                      'Spread ${c['spread_x'] ?? '—'} / ${c['spread_y'] ?? '—'} · projected point ${c['projected_label_x'] ?? '—'}, ${c['projected_label_y'] ?? '—'}',
                    ),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}
