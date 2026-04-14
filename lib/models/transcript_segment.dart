class TranscriptSegment {
  final double start;
  final double end;
  final String text;
  final String? speaker;
  final double? avgLogprob;
  final double? noSpeechProb;

  const TranscriptSegment({
    required this.start,
    required this.end,
    required this.text,
    this.speaker,
    this.avgLogprob,
    this.noSpeechProb,
  });

  factory TranscriptSegment.fromJson(Map<String, dynamic> json) {
    return TranscriptSegment(
      start: (json['start'] as num?)?.toDouble() ?? 0.0,
      end: (json['end'] as num?)?.toDouble() ?? 0.0,
      text: (json['text'] as String?) ?? '',
      speaker: json['speaker'] as String?,
      avgLogprob: (json['avg_logprob'] as num?)?.toDouble(),
      noSpeechProb: (json['no_speech_prob'] as num?)?.toDouble(),
    );
  }
}
