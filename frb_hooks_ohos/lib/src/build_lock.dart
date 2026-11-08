import 'dart:async';
import 'dart:io';

final _buildLockTails = <String, Future<void>>{};

Future<T> withOutputDirectoryBuildLock<T>(
  Uri outputDirectory,
  Future<T> Function() action,
) async {
  final lockFile = File.fromUri(
    outputDirectory.resolve('.flutter_rust_bridge_native_assets_build.lock'),
  );
  await lockFile.create(recursive: true);
  final resolvedPath = await lockFile.resolveSymbolicLinks();
  final key = Platform.isWindows ? resolvedPath.toLowerCase() : resolvedPath;
  final completion = Completer<void>();
  final previous = _buildLockTails[key];
  _buildLockTails[key] = completion.future;

  try {
    // POSIX locks belong to the process, so also serialize calls in this isolate.
    if (previous != null) await previous;
    // Append mode avoids truncating a lock file held by another build.
    final lock = await lockFile.open(mode: FileMode.append);
    try {
      await lock.lock(FileLock.blockingExclusive);
      try {
        return await action();
      } finally {
        await lock.unlock();
      }
    } finally {
      // Close even when acquiring or releasing the OS lock fails.
      await lock.close();
    }
  } finally {
    completion.complete();
    if (identical(_buildLockTails[key], completion.future)) {
      _buildLockTails.remove(key);
    }
  }
}
