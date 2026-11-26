import 'package:supabase_flutter/supabase_flutter.dart';

/// The states written by the server validation pipeline. Clients never infer a
/// verdict: unknown/missing values stay [unknown] until the RPC reports them.
enum NiptoMediaState {
  uploaded,
  queued,
  scanning,
  clean,
  needsReview,
  processing,
  ready,
  rejected,
  failed,
  unknown;

  static const _values = <String, NiptoMediaState>{
    'uploaded': uploaded,
    'queued': queued,
    'scanning': scanning,
    'clean': clean,
    'needs_review': needsReview,
    'processing': processing,
    'ready': ready,
    'rejected': rejected,
    'failed': failed,
  };

  static NiptoMediaState parse(Object? value) =>
      _values[value?.toString()] ?? unknown;

  String get wireName => switch (this) {
    NiptoMediaState.uploaded => 'uploaded',
    NiptoMediaState.queued => 'queued',
    NiptoMediaState.scanning => 'scanning',
    NiptoMediaState.clean => 'clean',
    NiptoMediaState.needsReview => 'needs_review',
    NiptoMediaState.processing => 'processing',
    NiptoMediaState.ready => 'ready',
    NiptoMediaState.rejected => 'rejected',
    NiptoMediaState.failed => 'failed',
    NiptoMediaState.unknown => 'unknown',
  };

  /// True when no further automatic state change is expected. A real scanner or
  /// processor may still move [processing] to ready; it is not settled here.
  bool get isSettled => switch (this) {
    NiptoMediaState.clean ||
    NiptoMediaState.needsReview ||
    NiptoMediaState.ready ||
    NiptoMediaState.rejected ||
    NiptoMediaState.failed => true,
    _ => false,
  };

  bool get isApproved =>
      this == NiptoMediaState.clean || this == NiptoMediaState.ready;
}

class NiptoMediaStatus {
  const NiptoMediaStatus({
    required this.state,
    this.exists = false,
    this.bucket,
    this.path,
    this.mime,
    this.size,
    this.sha256,
    this.attempts = 0,
    this.lastError,
    this.thumbnailPath,
    this.renditionPath,
    this.updatedAt,
  });

  factory NiptoMediaStatus.fromRpc(Object? raw) {
    if (raw is! Map)
      return const NiptoMediaStatus(state: NiptoMediaState.unknown);
    final row = Map<String, dynamic>.from(raw);
    return NiptoMediaStatus(
      exists: true,
      state: NiptoMediaState.parse(row['state']),
      bucket: row['bucket'] as String?,
      path: row['path'] as String?,
      mime: row['mime'] as String?,
      size: _asInt(row['size']),
      sha256: row['sha256'] as String?,
      attempts: _asInt(row['attempts']) ?? 0,
      lastError: row['last_error'] as String?,
      thumbnailPath: row['thumbnail_path'] as String?,
      renditionPath: row['rendition_path'] as String?,
      updatedAt: row['updated_at'] as String?,
    );
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  final NiptoMediaState state;
  final bool exists;
  final String? bucket;
  final String? path;
  final String? mime;
  final int? size;
  final String? sha256;
  final int attempts;
  final String? lastError;
  final String? thumbnailPath;
  final String? renditionPath;
  final String? updatedAt;

  /// Honest label for screens: never claims a verdict the server did not write.
  String get pendingLabel {
    if (!exists) return 'Validation pending';
    return switch (state) {
      NiptoMediaState.clean || NiptoMediaState.ready => 'Validated',
      NiptoMediaState.needsReview => 'Awaiting human review',
      NiptoMediaState.processing => 'Processing',
      NiptoMediaState.scanning => 'Checking media',
      NiptoMediaState.queued || NiptoMediaState.uploaded => 'Validation queued',
      NiptoMediaState.rejected => 'Rejected',
      NiptoMediaState.failed => 'Validation failed',
      NiptoMediaState.unknown => 'Validation pending',
    };
  }
}

/// Small seam so service behavior can be tested without a live Supabase client.
abstract class NiptoMediaTransport {
  Future<Object?> enqueue(String bucket, String path);

  Future<Object?> status(String bucket, String path);

  /// Invokes the Edge Function server-side validation. Errors leave the queued
  /// row intact and are surfaced through [status], never fabricated locally.
  Future<void> inspect(String bucket, String path);
}

class NiptoMediaSupabaseTransport implements NiptoMediaTransport {
  NiptoMediaSupabaseTransport({SupabaseClient? client})
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<Object?> enqueue(String bucket, String path) => _client.rpc(
    'nipto_media_enqueue',
    params: {'p_bucket': bucket, 'p_path': path},
  );

  @override
  Future<Object?> status(String bucket, String path) => _client.rpc(
    'nipto_media_status',
    params: {'p_bucket': bucket, 'p_path': path},
  );

  @override
  Future<void> inspect(String bucket, String path) async {
    await _client.functions.invoke(
      'nipto-media',
      body: {'bucket': bucket, 'path': path},
    );
  }
}

class NiptoMediaService {
  NiptoMediaService({NiptoMediaTransport? transport})
    : _transport = transport ?? NiptoMediaSupabaseTransport();

  final NiptoMediaTransport _transport;

  /// Called immediately after a successful private upload. The RPC records the
  /// real queued asset; the Edge Function then verifies the downloaded bytes.
  Future<NiptoMediaStatus> enqueue(String bucket, String path) async {
    await _transport.enqueue(bucket, path);
    try {
      await _transport.inspect(bucket, path);
    } catch (_) {
      // A missing or temporarily unavailable validator must not fabricate a
      // verdict or fail the upload. The queued row remains for retry/cleanup.
    }
    return status(bucket, path);
  }

  Future<NiptoMediaStatus> status(String bucket, String path) async =>
      NiptoMediaStatus.fromRpc(await _transport.status(bucket, path));

  /// Polls only the server-reported state. Use [Duration.zero] in tests.
  Future<NiptoMediaStatus> poll(
    String bucket,
    String path, {
    int maxAttempts = 5,
    Duration interval = const Duration(seconds: 2),
  }) async {
    final attempts = maxAttempts < 1 ? 1 : maxAttempts;
    for (var index = 0; index < attempts; index += 1) {
      final current = await status(bucket, path);
      if (current.state.isSettled || index == attempts - 1) return current;
      if (interval > Duration.zero) await Future<void>.delayed(interval);
    }
    return const NiptoMediaStatus(state: NiptoMediaState.unknown);
  }
}
