// Data models for the polls-in-chat feature.

/// A single poll option and its aggregated result.
class PollOption {
  const PollOption({
    required this.text,
    required this.count,
    required this.voters,
  });

  final String text;
  final int count;
  final List<String> voters;

  factory PollOption.fromJson(Map<String, dynamic> json) {
    return PollOption(
      text: (json['text'] as String?) ?? '',
      count: (json['count'] as int?) ?? 0,
      voters:
          (json['voters'] as List<dynamic>?)
              ?.map((v) => v.toString())
              .toList() ??
          [],
    );
  }
}

/// A poll and its current vote tallies returned by
/// `GET /api/messages/:id/poll`.
class Poll {
  const Poll({required this.question, required this.options, this.myVote});

  final String question;
  final List<PollOption> options;

  /// The option index the caller voted for, or null when they haven't voted.
  final int? myVote;

  int get totalVotes => options.fold(0, (sum, o) => sum + o.count);

  factory Poll.fromJson(Map<String, dynamic> json) {
    return Poll(
      question: (json['question'] as String?) ?? '',
      options:
          (json['options'] as List<dynamic>?)
              ?.map(
                (e) => PollOption.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList() ??
          [],
      myVote: (json['my_vote'] as num?)?.toInt(),
    );
  }
}
