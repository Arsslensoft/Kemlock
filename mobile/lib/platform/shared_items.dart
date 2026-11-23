import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/providers.dart';
import '../core/toasts.dart';
import '../crypto/bytes.dart';
import '../crypto/keys/pgp.dart' show maxPgpTextLength;
import '../i18n/messages.dart';

/// What another app hands Kemlock through the phone's share sheet
/// (openspec: add-share-extension): an item, or word that one could not be
/// taken.
@immutable
sealed class SharedArrival {
  const SharedArrival();

  /// Reads what the native side hands over on `com.kemlock.app/share`:
  /// `{"text": …}` for a text, `{"path", "name", "size", "type"}` for a file
  /// it copied into the app's own `share/` directory, `{"error":
  /// "unreadable" | "noRoom"}` for one it could not take, each with an
  /// optional `"at"`, when it was shared, in milliseconds since 1970. Null
  /// for anything else, which is dropped.
  static SharedArrival? fromChannel(Object? value) {
    if (value is! Map) return null;
    final at = value['at'];
    final sharedAt = at is int ? DateTime.fromMillisecondsSinceEpoch(at, isUtc: true) : null;
    final error = value['error'];
    if (error is String) {
      return switch (error) {
        'noRoom' => const SharedRefused(SharedProblem.noRoom),
        _ => const SharedRefused(SharedProblem.unreadable),
      };
    }
    final text = value['text'];
    final path = value['path'];
    if (path is String && path.isNotEmpty) {
      final name = value['name'];
      final size = value['size'];
      final type = value['type'];
      return SharedFile(
        path: path,
        name: name is String && name.isNotEmpty ? name : path.split(RegExp(r'[/\\]')).last,
        size: size is int ? size : 0,
        type: type is String && type.isNotEmpty ? type : null,
        sharedAt: sharedAt,
      );
    }
    if (text is String && text.isNotEmpty) return SharedText(text, sharedAt: sharedAt);
    return null;
  }
}

/// A text or one file another app shared, waiting for an open vault.
sealed class SharedItem extends SharedArrival {
  const SharedItem({this.sharedAt});

  /// When it was shared, where the phone says so: on iOS the share screen
  /// writes it, and the item may wait there before the app is opened.
  final DateTime? sharedAt;
}

/// Shared text. On Android it is kept in memory only.
final class SharedText extends SharedItem {
  const SharedText(this.text, {super.sharedAt});

  final String text;
}

/// A shared file, copied into the app's own `share/` temporary directory
/// and read from there by its path, never whole into memory.
final class SharedFile extends SharedItem {
  const SharedFile({required this.path, required this.name, required this.size, this.type, super.sharedAt});

  final String path;
  final String name;

  /// In bytes.
  final int size;

  /// The media type the other app gave, when it gave one.
  final String? type;
}

/// Why a share could not be taken.
enum SharedProblem {
  /// The other app's file could not be read, or was withdrawn.
  unreadable,

  /// The phone had no room left for the copy.
  noRoom,
}

/// A share that was refused, with nothing of it kept.
final class SharedRefused extends SharedArrival {
  const SharedRefused(this.problem);

  final SharedProblem problem;
}

/// What other apps share to Kemlock: the item the app was opened with,
/// once, and those that arrive while it runs, as `SetupLinks` has for
/// links.
abstract interface class SharedItems {
  /// What the app was opened with, once; null when there was nothing.
  Future<SharedArrival?> initial();

  /// What arrives while the app runs.
  Stream<SharedArrival> get incoming;

  /// Deletes whatever the native side still keeps of a share: on iOS, the
  /// hand-over files in the App Group.
  Future<void> clear();
}

/// [SharedItems] over the app's method channel; a build without the native
/// side gets nothing.
class ChannelSharedItems implements SharedItems {
  ChannelSharedItems() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'item') return;
      final arrival = SharedArrival.fromChannel(call.arguments);
      if (arrival != null) _incoming.add(arrival);
    });
  }

  static const _channel = MethodChannel('com.kemlock.app/share');
  final _incoming = StreamController<SharedArrival>.broadcast();

  @override
  Future<SharedArrival?> initial() async {
    try {
      return SharedArrival.fromChannel(await _channel.invokeMethod<Object?>('initial'));
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Stream<SharedArrival> get incoming => _incoming.stream;

  @override
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clear');
    } on MissingPluginException {
      // Nothing native to clear
    }
  }
}

/// The phone's shared items; tests put a fake in its place.
final sharedItemsProvider = Provider<SharedItems>((ref) => ChannelSharedItems());

/// How long a shared item waits for a vault to be opened, and how old a
/// file in the `share/` directory may get before a sweep deletes it.
const sharedItemLife = Duration(minutes: 10);

/// The directory shared files wait in, `<temporary directory>/share`: the
/// native side puts each one there as `<random>/<name>`. The phone's cache,
/// which is the app's own and out of its backups. Tests point it at a
/// directory of their own.
final shareTempRootProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory('${(await getTemporaryDirectory()).path}${Platform.pathSeparator}share'),
);

/// Deletes the file at [path] and the directory it was put in, when that
/// is left empty. Never throws: what is left, the next sweep takes.
void deleteSharedFile(String path) {
  try {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
    final directory = file.parent;
    if (directory.existsSync() && directory.listSync().isEmpty) directory.deleteSync();
  } on FileSystemException {
    // Swept later
  }
}

/// Deletes what waited under [root] for longer than [sharedItemLife] at
/// [now]: each file by the time it was last written, which is when it was
/// shared, and then the directories it leaves empty that are as old. The
/// files in [keep] (the item still waiting, or one a sheet is working on)
/// stay whatever their age. Never throws.
void sweepSharedFiles(Directory root, DateTime now, {Iterable<String> keep = const []}) {
  final cutoff = now.subtract(sharedItemLife);
  try {
    if (!root.existsSync()) return;
    final kept = {for (final path in keep) _canonical(path)};
    final entries = root.listSync(recursive: true, followLinks: false);
    for (final file in entries.whereType<File>()) {
      if (!kept.contains(_canonical(file.path)) && file.statSync().modified.isBefore(cutoff)) file.deleteSync();
    }
    // The deepest first, so a directory emptied by the one inside it goes too
    final directories = entries.whereType<Directory>().toList()..sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final directory in directories) {
      if (directory.listSync().isEmpty && directory.statSync().modified.isBefore(cutoff)) directory.deleteSync();
    }
  } on FileSystemException {
    // Tried again on the next start or return to the front
  }
}

String _canonical(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return File(path).absolute.path;
  }
}

/// The newest shared item, waiting until a vault is open (openspec:
/// add-share-extension, decision 4). The lock screen shows that one waits;
/// the open vault's shell takes it. It is forgotten when taken, dropped
/// ("Not now", a refused share after it), [sharedItemLife] after it was
/// shared, and when every vault is erased; a newer item replaces it.
///
/// A file it forgets is deleted; a file taken is the taker's to delete.
class PendingShare extends Notifier<SharedItem?> {
  Timer? _timer;
  DateTime? _arrivedAt;

  /// Counts arrivals, so that one that took a while to write is not kept
  /// over a newer one.
  var _arrivals = 0;

  /// Files handed to a sheet and still being worked on, which the sweep
  /// leaves alone.
  final _inUse = <String>{};

  @override
  SharedItem? build() {
    final items = ref.watch(sharedItemsProvider);
    final sub = items.incoming.listen((arrival) => unawaited(_arrived(arrival)));
    ref.onDispose(() {
      unawaited(sub.cancel());
      _timer?.cancel();
    });
    unawaited(items.initial().then((arrival) => arrival == null ? null : _arrived(arrival)).catchError((Object _) {}));
    // Whatever a killed app left behind, except what is still young enough to be offered
    unawaited(sweep());
    return null;
  }

  Future<void> _arrived(SharedArrival arrival) async {
    final arrivals = ++_arrivals;
    switch (arrival) {
      case SharedRefused(:final problem):
        // The newest share counts, and it is refused: nothing waits
        drop();
        _say(problem);
      case SharedText(:final text, :final sharedAt) when utf8.encode(text).length > maxPgpTextLength:
        // Longer than the sheets show as text: taken as a file
        final SharedFile file;
        try {
          file = await _writeText(text, sharedAt);
        } on FileSystemException {
          if (arrivals == _arrivals) {
            drop();
            _say(SharedProblem.noRoom);
          }
          return;
        }
        if (arrivals != _arrivals || !ref.mounted) return deleteSharedFile(file.path);
        _hold(file);
      case final SharedItem item:
        _hold(item);
    }
  }

  Future<SharedFile> _writeText(String text, DateTime? sharedAt) async {
    final root = await ref.read(shareTempRootProvider)();
    final name = [for (final b in randomBytes(8)) b.toRadixString(16).padLeft(2, '0')].join();
    final directory = Directory('${root.path}${Platform.pathSeparator}$name');
    final file = File('${directory.path}${Platform.pathSeparator}shared.txt');
    try {
      directory.createSync(recursive: true);
      file.writeAsStringSync(text, flush: true);
    } on FileSystemException {
      // No partial copy is left
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Swept later
      }
      rethrow;
    }
    return SharedFile(path: file.path, name: 'shared.txt', size: file.lengthSync(), type: 'text/plain', sharedAt: sharedAt);
  }

  void _hold(SharedItem item) {
    final now = ref.read(clockProvider)();
    final sharedAt = item.sharedAt;
    final arrivedAt = sharedAt != null && sharedAt.isBefore(now) ? sharedAt : now;
    final left = sharedItemLife - now.difference(arrivedAt);
    final old = state;
    _timer?.cancel();
    _timer = null;
    if (old is SharedFile && (item is! SharedFile || item.path != old.path)) deleteSharedFile(old.path);
    if (left <= Duration.zero) {
      // Shared too long ago to be offered
      _arrivedAt = null;
      state = null;
      if (item is SharedFile) deleteSharedFile(item.path);
      return;
    }
    _arrivedAt = arrivedAt;
    _timer = Timer(left, drop);
    state = item;
  }

  void _say(SharedProblem problem) {
    final messages = ref.read(messagesProvider);
    ref
        .read(toastsProvider.notifier)
        .show(
          messages.t(switch (problem) {
            SharedProblem.unreadable => 'share.unreadable',
            SharedProblem.noRoom => 'share.noRoom',
          }),
          severity: ToastSeverity.error,
        );
  }

  /// The item, now handed on, and forgotten. A file stays where it is,
  /// for the taker to delete when it is done.
  SharedItem? take() {
    final item = state;
    _timer?.cancel();
    _timer = null;
    _arrivedAt = null;
    state = null;
    return item;
  }

  /// Forgets the item and deletes its file: "Not now", and the ten minutes.
  void drop() {
    final item = take();
    if (item is SharedFile) deleteSharedFile(item.path);
  }

  /// [path], a shared file a sheet now works on, is left alone by the
  /// sweep; the sheet deletes it when it is done.
  void inUse(String path) => _inUse.add(path);

  /// Every vault was erased: the item goes, the `share/` directory is
  /// emptied, and the native side deletes what it still keeps.
  Future<void> wipe() async {
    drop();
    _inUse.clear();
    try {
      final root = await ref.read(shareTempRootProvider)();
      if (root.existsSync()) root.deleteSync(recursive: true);
    } on Object {
      // Nothing to empty, or the system's to clear
    }
    try {
      await ref.read(sharedItemsProvider).clear();
    } on Object {
      // Nothing native to clear
    }
  }

  /// The app came back to the front: an item shared [sharedItemLife] ago
  /// or more is forgotten, as the timer may not have run while the phone
  /// slept, and the `share/` directory is swept.
  Future<void> resumed() async {
    final arrivedAt = _arrivedAt;
    if (arrivedAt != null && ref.read(clockProvider)().difference(arrivedAt) >= sharedItemLife) drop();
    await sweep();
  }

  /// Deletes the files in the `share/` directory older than
  /// [sharedItemLife], except the waiting item's and those in use.
  Future<void> sweep() async {
    try {
      final root = await ref.read(shareTempRootProvider)();
      // Read once the directory is known, which is after build at start
      final waiting = state;
      // A file in use that is gone needs no keeping any more
      _inUse.removeWhere((path) => !File(path).existsSync());
      sweepSharedFiles(root, ref.read(clockProvider)(), keep: {..._inUse, if (waiting is SharedFile) waiting.path});
    } on Object {
      // No temporary directory to speak of, or the app is closing
    }
  }
}

final pendingShareProvider = NotifierProvider<PendingShare, SharedItem?>(PendingShare.new);
