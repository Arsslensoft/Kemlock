/// Fetching the files attached to notes that sync named and this phone
/// lacks (step 5 of `attachment_sync.dart`), outside the sync run, one at a
/// time, the smallest first. Each download is checked by decrypting it
/// with its key before it is stored: a file that doesn't open is thrown
/// away and fetched again later.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../crypto/attachment_format.dart';
import '../../crypto/bytes.dart';
import '../../models/secure_note.dart';
import '../../platform/network.dart';
import '../../vault/attachment_store.dart';
import '../../vault/vault_registry.dart';
import 'attachment_sync.dart';
import 'sync_store.dart';
import 'webdav.dart';

/// Where an attached file stands on this phone.
enum AttachmentStatus {
  /// Stored, and opens.
  here,

  /// Being downloaded.
  fetching,

  /// Not fetched yet: no connection, the last try failed, or offline mode
  /// is on. Tried again after the next sync, when the file is opened, or
  /// when offline mode is turned off.
  waiting,

  /// Neither this phone nor the sync folder has it.
  missing,
}

/// A file to fetch, and where from.
typedef _Wanted = ({String vaultId, DavAccount dav, NoteAttachment file});

/// The downloads of attached files, and each one's status by attachment id.
/// A file that never needed fetching has no entry.
class AttachmentDownloads extends Notifier<Map<String, AttachmentStatus>> {
  final _wanted = <String, _Wanted>{};
  String? _first;
  var _running = false;

  @override
  Map<String, AttachmentStatus> build() {
    // Files wait while offline mode is on, and are fetched when it is turned off. Heard from the
    // store itself: nothing may be watching this provider then, and a provider no one watches is paused.
    final store = ref.watch(keyValueStoreProvider);
    final stop = store.listen(keyOffline, () {
      if (!readOffline(store)) unawaited(_pump());
    });
    ref.onDispose(stop);
    return const {};
  }

  AttachmentStore get _store => ref.read(attachmentStoreProvider);

  bool get _offline => ref.read(networkGateProvider).offline;

  void _set(String id, AttachmentStatus status) => state = {...state, id: status};

  /// Takes the files sync found [vaultId]'s notes name and this phone
  /// lacks, to fetch from [dav], and starts fetching.
  void want(String vaultId, DavAccount dav, List<NoteAttachment> files) {
    for (final file in files) {
      if (state[file.id] == AttachmentStatus.fetching) continue;
      _wanted[file.id] = (vaultId: vaultId, dav: dav, file: file);
      _set(file.id, AttachmentStatus.waiting);
    }
    unawaited(_pump());
  }

  /// Fetches [id] before the others, as when its note opens it. False when
  /// no sync folder is known to have it.
  bool fetchNow(String id) {
    if (!_wanted.containsKey(id)) return false;
    _first = id;
    unawaited(_pump());
    return true;
  }

  Future<void> _pump() async {
    // Offline mode: every file stays waiting, and no request is made
    if (_offline) return;
    if (_running) return;
    _running = true;
    final failed = <String>{};
    try {
      while (true) {
        final pending = [
          for (final wanted in _wanted.values)
            if (!failed.contains(wanted.file.id)) wanted,
        ];
        if (pending.isEmpty) break;
        // Turned on in the middle: the rest wait
        if (_offline) break;
        final first = _first;
        _first = null;
        pending.sort((a, b) => a.file.size.compareTo(b.file.size));
        final next = pending.firstWhere((wanted) => wanted.file.id == first, orElse: () => pending.first);
        if (!await _fetch(next)) failed.add(next.file.id);
      }
    } finally {
      _running = false;
    }
  }

  /// One download; false when it should be tried again later.
  Future<bool> _fetch(_Wanted wanted) async {
    final id = wanted.file.id;
    if (await _store.exists(wanted.vaultId, id)) {
      _wanted.remove(id);
      _set(id, AttachmentStatus.here);
      return true;
    }
    _set(id, AttachmentStatus.fetching);
    try {
      // No file a note takes is longer, sealed; a server's answer past that is no such file
      final bytes = await ref.read(webDavProvider).readBytes(wanted.dav, syncedFileName(id), maxBytes: kma1Length(attachmentSizeLimit));
      if (bytes == null) {
        _wanted.remove(id);
        _set(id, AttachmentStatus.missing);
        return true;
      }
      // Only a file its key opens is kept
      await kma1Decrypt(bytes, unb64(wanted.file.key));
      await _store.writeSealed(wanted.vaultId, id, bytes);
      _wanted.remove(id);
      _set(id, AttachmentStatus.here);
      return true;
    } catch (_) {
      _set(id, AttachmentStatus.waiting);
      return false;
    }
  }
}

/// The attached files being fetched, and how each stands.
final attachmentDownloadsProvider = NotifierProvider<AttachmentDownloads, Map<String, AttachmentStatus>>(AttachmentDownloads.new);
