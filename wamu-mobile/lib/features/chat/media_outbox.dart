import 'dart:convert';
import 'dart:typed_data';

import 'package:uuid/uuid.dart';

import '../../core/storage/kv_store.dart';
import '../../core/storage/secure_storage.dart';
import 'media_file_store_stub.dart'
    if (dart.library.io) 'media_file_store_io.dart' as disk;
import 'message_outbox.dart';

enum MediaOutboxStatus { queued, uploading, failed }

/// Pending media uploads — disk-backed on IO platforms; web uses small base64 / session.
class MediaOutboxEntry {
  const MediaOutboxEntry({
    required this.id,
    required this.conversationId,
    required this.filename,
    required this.contentType,
    required this.messageType,
    required this.createdAt,
    this.caption = '',
    this.status = MediaOutboxStatus.queued,
    this.attempts = 0,
    this.lastError,
    this.persistedBase64,
    this.localPath,
  });

  factory MediaOutboxEntry.fromJson(Map<String, dynamic> json) {
    return MediaOutboxEntry(
      id: json['id']?.toString() ?? '',
      conversationId: json['conversation_id']?.toString() ?? '',
      filename: json['filename']?.toString() ?? 'file.bin',
      contentType: json['content_type']?.toString() ?? 'application/octet-stream',
      messageType: json['message_type']?.toString() ?? 'IMAGE',
      caption: json['caption']?.toString() ?? '',
      createdAt: json['created_at']?.toString() ?? DateTime.now().toIso8601String(),
      status: MediaOutboxStatus.values.firstWhere(
        (s) => s.name == json['status'],
        orElse: () => MediaOutboxStatus.queued,
      ),
      attempts: int.tryParse('${json['attempts']}') ?? 0,
      lastError: json['last_error']?.toString(),
      persistedBase64: json['b64']?.toString(),
      localPath: json['local_path']?.toString(),
    );
  }

  final String id;
  final String conversationId;
  final String filename;
  final String contentType;
  final String messageType;
  final String caption;
  final String createdAt;
  final MediaOutboxStatus status;
  final int attempts;
  final String? lastError;
  final String? persistedBase64;
  final String? localPath;

  Map<String, dynamic> toJson() => {
        'id': id,
        'conversation_id': conversationId,
        'filename': filename,
        'content_type': contentType,
        'message_type': messageType,
        'caption': caption,
        'created_at': createdAt,
        'status': status.name,
        'attempts': attempts,
        if (lastError != null) 'last_error': lastError,
        if (persistedBase64 != null) 'b64': persistedBase64,
        if (localPath != null) 'local_path': localPath,
      };

  MediaOutboxEntry copyWith({
    MediaOutboxStatus? status,
    int? attempts,
    String? lastError,
    String? persistedBase64,
    String? localPath,
  }) {
    return MediaOutboxEntry(
      id: id,
      conversationId: conversationId,
      filename: filename,
      contentType: contentType,
      messageType: messageType,
      caption: caption,
      createdAt: createdAt,
      status: status ?? this.status,
      attempts: attempts ?? this.attempts,
      lastError: lastError,
      persistedBase64: persistedBase64 ?? this.persistedBase64,
      localPath: localPath ?? this.localPath,
    );
  }
}

class MediaOutbox {
  MediaOutbox({
    required OutboxReader read,
    required OutboxWriter write,
  })  : _read = read,
        _write = write;

  factory MediaOutbox.fromKv(KvStore store) {
    return MediaOutbox(read: store.read, write: store.write);
  }

  factory MediaOutbox.fromSecure(SecureStorageService storage) {
    return MediaOutbox(read: storage.read, write: storage.write);
  }

  final OutboxReader _read;
  final OutboxWriter _write;
  static const _key = 'wamu_media_outbox_v1';
  static const _uuid = Uuid();
  static const _maxBase64Bytes = 200 * 1024;

  static final Map<String, Uint8List> sessionBytes = {};

  Future<List<MediaOutboxEntry>> _loadMeta() async {
    final raw = await _read(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .whereType<Map>()
          .map((e) => MediaOutboxEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _saveMeta(List<MediaOutboxEntry> entries) async {
    await _write(_key, jsonEncode(entries.map((e) => e.toJson()).toList()));
  }

  Future<MediaOutboxEntry> enqueue({
    required String conversationId,
    required Uint8List bytes,
    required String filename,
    required String contentType,
    String messageType = 'IMAGE',
    String caption = '',
  }) async {
    final id = 'media-${_uuid.v4()}';
    final localPath = await disk.writeMediaFile(id: id, filename: filename, bytes: bytes);
    String? b64;
    if (localPath == null) {
      if (bytes.lengthInBytes <= _maxBase64Bytes) {
        b64 = base64Encode(bytes);
      } else {
        sessionBytes[id] = bytes;
      }
    }

    final entry = MediaOutboxEntry(
      id: id,
      conversationId: conversationId,
      filename: filename,
      contentType: contentType,
      messageType: messageType,
      caption: caption,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      persistedBase64: b64,
      localPath: localPath,
    );
    final all = await _loadMeta();
    all.add(entry);
    await _saveMeta(all);
    return entry;
  }

  Future<Uint8List?> bytesFor(MediaOutboxEntry entry) async {
    if (entry.localPath != null) {
      final fromDisk = await disk.readMediaFile(entry.localPath!);
      if (fromDisk != null) return fromDisk;
    }
    if (entry.persistedBase64 != null && entry.persistedBase64!.isNotEmpty) {
      try {
        return base64Decode(entry.persistedBase64!);
      } catch (_) {}
    }
    return sessionBytes[entry.id];
  }

  Future<List<MediaOutboxEntry>> allPending() => _loadMeta();

  Future<void> markUploading(String id) async {
    final all = await _loadMeta();
    await _saveMeta([
      for (final e in all)
        if (e.id == id)
          e.copyWith(status: MediaOutboxStatus.uploading, attempts: e.attempts + 1)
        else
          e,
    ]);
  }

  Future<void> markDone(String id) async {
    sessionBytes.remove(id);
    final all = await _loadMeta();
    for (final e in all.where((e) => e.id == id)) {
      if (e.localPath != null) {
        await disk.deleteMediaFile(e.localPath!);
      }
    }
    await _saveMeta(all.where((e) => e.id != id).toList());
  }

  Future<void> markFailed(String id, String error) async {
    final all = await _loadMeta();
    await _saveMeta([
      for (final e in all)
        if (e.id == id)
          e.copyWith(status: MediaOutboxStatus.failed, lastError: error)
        else
          e,
    ]);
  }
}
