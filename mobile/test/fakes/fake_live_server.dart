import 'dart:async';

import 'package:flutter_riverpod/misc.dart';
import 'package:kemlock/platform/network.dart';

/// One socket of the fake server: what the server sends, and what the phone closed.
class FakeLiveSocket implements LiveSocket {
  FakeLiveSocket(this.url, this.headers, this.pin);

  final Uri url;
  final Map<String, String> headers;
  final String? pin;

  final _frames = StreamController<String>();

  /// Whether the phone closed it.
  bool closed = false;

  @override
  Stream<String> get frames => _frames.stream;

  @override
  Future<void> close() async {
    if (closed) {
      return;
    }
    closed = true;
    if (!_frames.isClosed) {
      unawaited(_frames.close());
    }
  }

  /// The server sends [frame].
  void send(String frame) => _frames.add(frame);

  /// The server drops the connection.
  Future<void> drop() async {
    if (!_frames.isClosed) {
      unawaited(_frames.close());
    }
  }
}

/// A fake of `/kem/v1/live`: it accepts each connection unless [refuse] is set, and keeps them all.
class FakeLiveServer {
  /// Every connection attempt, as the address it was made to, in order, whether or not it was taken.
  final List<Uri> attempts = [];

  /// Every connection taken, in order.
  final List<FakeLiveSocket> sockets = [];

  /// Refuse each attempt, as a server that is down does.
  bool refuse = false;

  /// The socket open now, or null.
  FakeLiveSocket? get current => sockets.isEmpty || sockets.last.closed ? null : sockets.last;

  Future<LiveSocket> connect(Uri url, {Map<String, String> headers = const {}, String? pin}) async {
    attempts.add(url);
    if (refuse) {
      throw const FormatException('refused');
    }
    final socket = FakeLiveSocket(url, headers, pin);
    sockets.add(socket);
    return socket;
  }

  Override get asOverride => liveSocketConnectorProvider.overrideWithValue(connect);
}
