import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:sqlcipher_bridge/index.dart' as lib;

void main() async {
  print(version());
}

String version() {
  return using((arena) {
    final ppDb = arena<Pointer<lib.sqlite3>>();

    var rc = lib.sqlite3_open(
      ":memory:".toNativeUtf8(allocator: arena).cast(),
      ppDb,
    );
    if (rc != lib.SQLITE_OK) {
      throw Exception(rc);
    }
    final db = ppDb.value;

    final ppStatement = arena<Pointer<lib.sqlite3_stmt>>();
    rc = lib.sqlite3_prepare_v2(
      db,
      "PRAGMA cipher_version".toNativeUtf8(allocator: arena).cast(),
      -1,
      ppStatement,
      nullptr,
    );
    if (rc != lib.SQLITE_OK) {
      throw Exception(rc);
    }
    final s = ppStatement.value;
    if (s == nullptr) {
      throw Exception(lib.SQLITE_ERROR);
    }
    rc = lib.sqlite3_step(s);
    if (rc != lib.SQLITE_ROW) {
      throw Exception(rc);
    }
    final cipherVersion = lib
        .sqlite3_column_text(s, 0)
        .cast<Utf8>()
        .toDartString();

    lib.sqlite3_close(db);

    return cipherVersion;
  });
}
