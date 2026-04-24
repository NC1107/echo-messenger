/// Fuzzy matching helper for search & filter UIs.
///
/// Returns a score in `[0, 1]` for how well [query] matches [candidate]:
///   * 0 = no match (not all query characters found in order)
///   * 1 = all query characters appear consecutively at the start
///
/// Matching is case-insensitive. Consecutive matches ("runs") receive a small
/// bonus so prefix/contiguous matches score higher than scattered ones.
///
/// Use together with a threshold (e.g. `> 0.3`) to filter and sort results.
double fuzzyScore(String query, String candidate) {
  if (query.isEmpty) return 0;
  final q = query.toLowerCase();
  final c = candidate.toLowerCase();

  int qi = 0;
  int consecutive = 0;
  double score = 0;

  for (int ci = 0; ci < c.length && qi < q.length; ci++) {
    if (c[ci] == q[qi]) {
      score += 1 + consecutive * 0.5; // bonus for runs
      consecutive++;
      qi++;
    } else {
      consecutive = 0;
    }
  }

  // Not all query characters were matched in order -> no match.
  if (qi < q.length) return 0;

  // Normalize by the maximum achievable score (all characters consecutive).
  // Sum of 1 + 0.5 * i for i in [0, n-1] = n + 0.5 * n * (n - 1) / 2.
  final n = q.length;
  final maxScore = n + 0.5 * n * (n - 1) / 2;
  if (maxScore <= 0) return 0;

  return (score / maxScore).clamp(0.0, 1.0);
}
