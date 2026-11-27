import 'package:supabase_flutter/supabase_flutter.dart';

/// Privacy request kinds accepted by the `nipto-privacy` Edge Function.
enum NiptoPrivacyKind {
  export,
  deletion;

  String get wireValue => name;
}

/// Request states mirrored from `public.privacy_requests`.
enum NiptoPrivacyStatus {
  pending,
  processing,
  completed,
  failed,
  canceled;

  String get wireValue => name;

  static NiptoPrivacyStatus? fromWire(Object? value) {
    for (final status in NiptoPrivacyStatus.values) {
      if (status.wireValue == value) return status;
    }
    return null;
  }
}

class NiptoPrivacyException implements Exception {
  const NiptoPrivacyException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class NiptoPrivacyRequest {
  const NiptoPrivacyRequest({
    required this.id,
    required this.kind,
    required this.status,
    required this.requestedAt,
    required this.executeAfter,
    this.completedAt,
    this.canceledAt,
    required this.attempts,
  });

  final String id;
  final NiptoPrivacyKind kind;
  final NiptoPrivacyStatus status;
  final DateTime requestedAt;
  final DateTime executeAfter;
  final DateTime? completedAt;
  final DateTime? canceledAt;
  final int attempts;

  bool get isPendingDeletion =>
      kind == NiptoPrivacyKind.deletion && status == NiptoPrivacyStatus.pending;

  bool get isCompletedExport =>
      kind == NiptoPrivacyKind.export && status == NiptoPrivacyStatus.completed;

  factory NiptoPrivacyRequest.fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final kind = switch (json['kind']) {
      'export' => NiptoPrivacyKind.export,
      'deletion' => NiptoPrivacyKind.deletion,
      _ => null,
    };
    final status = NiptoPrivacyStatus.fromWire(
      json['kind'] == null ? null : json['status'],
    );
    final requestedAt = DateTime.tryParse(
      json['requested_at'] as String? ?? '',
    );
    final executeAfter = DateTime.tryParse(
      json['execute_after'] as String? ?? '',
    );
    final completedAt = _optionalDate(json['completed_at']);
    final canceledAt = _optionalDate(json['canceled_at']);
    final attemptsValue = json['attempts'];
    final attempts = attemptsValue is int
        ? attemptsValue
        : attemptsValue is num
        ? attemptsValue.toInt()
        : null;

    if (id == null ||
        !_uuid.hasMatch(id) ||
        kind == null ||
        status == null ||
        requestedAt == null ||
        executeAfter == null ||
        attempts == null ||
        attempts < 0) {
      throw const FormatException('Invalid privacy request payload');
    }
    return NiptoPrivacyRequest(
      id: id,
      kind: kind,
      status: status,
      requestedAt: requestedAt,
      executeAfter: executeAfter,
      completedAt: completedAt,
      canceledAt: canceledAt,
      attempts: attempts,
    );
  }

  static DateTime? _optionalDate(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

class NiptoPrivacyExportUrl {
  const NiptoPrivacyExportUrl({
    required this.signedUrl,
    required this.expiresAt,
  });

  final String signedUrl;
  final DateTime expiresAt;

  factory NiptoPrivacyExportUrl.fromJson(Map<String, dynamic> json) {
    final signedUrl = json['signed_url'] as String?;
    final expiresAt = DateTime.tryParse(json['expires_at'] as String? ?? '');
    if (signedUrl == null || signedUrl.isEmpty || expiresAt == null) {
      throw const FormatException('Invalid privacy export URL payload');
    }
    return NiptoPrivacyExportUrl(signedUrl: signedUrl, expiresAt: expiresAt);
  }
}

typedef NiptoPrivacyInvoke =
    Future<FunctionResponse> Function(
      String path, {
      Object? body,
      HttpMethod? method,
    });

/// Thin callable boundary that lets tests supply a fake invoker. Production
/// uses the initialized Supabase client, which attaches the user's bearer.
class NiptoPrivacySupabaseTransport {
  NiptoPrivacySupabaseTransport({
    SupabaseClient? client,
    NiptoPrivacyInvoke? invoker,
  }) : _invoker =
           invoker ??
           ((String path, {Object? body, HttpMethod? method}) =>
               (client ?? Supabase.instance.client).functions.invoke(
                 'nipto-privacy/$path',
                 body: body,
                 method: method ?? HttpMethod.post,
               ));

  final NiptoPrivacyInvoke _invoker;

  Future<Object?> invoke(String path, {required Object body}) async {
    try {
      final response = await _invoker(
        path,
        body: body,
        method: HttpMethod.post,
      );
      return response.data;
    } on FunctionException catch (error) {
      throw NiptoPrivacyException(
        _errorMessage(error.details, fallback: 'Privacy request was rejected.'),
        statusCode: error.status,
      );
    }
  }
}

class NiptoPrivacyService {
  NiptoPrivacyService({NiptoPrivacySupabaseTransport? transport})
    : _transport = transport ?? NiptoPrivacySupabaseTransport();

  final NiptoPrivacySupabaseTransport _transport;

  Future<List<NiptoPrivacyRequest>> status() async {
    final data = await _transport.invoke(
      'status',
      body: const <String, dynamic>{},
    );
    final payload = _asMap(data);
    final rows = payload['requests'];
    if (rows is! List) {
      throw const NiptoPrivacyException('Privacy status response was invalid.');
    }
    try {
      return rows
          .map(
            (row) => NiptoPrivacyRequest.fromJson(
              Map<String, dynamic>.from(row as Map),
            ),
          )
          .toList(growable: false);
    } on FormatException {
      throw const NiptoPrivacyException('Privacy status response was invalid.');
    } on TypeError {
      throw const NiptoPrivacyException('Privacy status response was invalid.');
    }
  }

  Future<String> request(NiptoPrivacyKind kind) async {
    final data = await _transport.invoke(
      'request',
      body: <String, dynamic>{'kind': kind.wireValue},
    );
    final payload = _asMap(data);
    final requestId = payload['request_id'] as String?;
    if (requestId == null || !_uuid.hasMatch(requestId)) {
      throw const NiptoPrivacyException(
        'Privacy request response was invalid.',
      );
    }
    return requestId;
  }

  Future<bool> cancelDeletion() async {
    final data = await _transport.invoke(
      'cancel',
      body: const <String, dynamic>{},
    );
    final payload = _asMap(data);
    final canceled = payload['canceled'];
    if (canceled is! bool) {
      throw const NiptoPrivacyException('Cancellation response was invalid.');
    }
    return canceled;
  }

  Future<NiptoPrivacyExportUrl> exportUrl(String requestId) async {
    if (!_uuid.hasMatch(requestId)) {
      throw const NiptoPrivacyException('Enter a valid export request.');
    }
    final data = await _transport.invoke(
      'export-url',
      body: <String, dynamic>{'request_id': requestId},
    );
    try {
      return NiptoPrivacyExportUrl.fromJson(_asMap(data));
    } on FormatException {
      throw const NiptoPrivacyException('Export response was invalid.');
    }
  }
}

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

Map<String, dynamic> _asMap(Object? data) {
  if (data is Map) return Map<String, dynamic>.from(data);
  throw const NiptoPrivacyException('Privacy response was invalid.');
}

String _errorMessage(Object? details, {required String fallback}) {
  if (details is Map) {
    final error = details['error'];
    if (error is Map) {
      final message = error['message'];
      if (message is String && message.trim().isNotEmpty) return message;
    }
    if (error is String && error.trim().isNotEmpty) return error;
    final message = details['message'];
    if (message is String && message.trim().isNotEmpty) return message;
  }
  if (details is String && details.trim().isNotEmpty) return details;
  return fallback;
}
