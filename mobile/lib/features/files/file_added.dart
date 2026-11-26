import '../../models/vault_file.dart';

/// When a File item was added, in epoch milliseconds: its own `addedAt`, or, for one the web vault made with none, the day its file was
/// attached. Never 0, so the item doesn't read as 1970 or sort as the oldest.
int fileAddedAt(VaultFile item) => item.addedAt != 0 ? item.addedAt : item.file.addedAt;
