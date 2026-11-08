import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_rust_bridge_hooks/src/build_lock.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporaryDirectory;
  late Uri outputDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'frb_lock_test_',
    );
    outputDirectory = temporaryDirectory.uri.resolve('output/');
  });

  tearDown(() async {
    await temporaryDirectory.delete(recursive: true);
  });

  test('concurrent calls wait and execute in order', () async {
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final events = <String>[];
    final first = withOutputDirectoryBuildLock(outputDirectory, () async {
      events.add('first entered');
      firstEntered.complete();
      await releaseFirst.future;
      events.add('first finished');
      return 1;
    });
    await firstEntered.future;

    final second = withOutputDirectoryBuildLock(outputDirectory, () async {
      events.add('second entered');
      return 2;
    });
    final results = Future.wait([first, second]);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events, ['first entered']);
    } finally {
      releaseFirst.complete();
      await results;
    }
    expect(await results, [1, 2]);
    expect(events, ['first entered', 'first finished', 'second entered']);
  });

  test('an action failure preserves the error and releases the lock', () async {
    final failure = StateError('build failed');
    await expectLater(
      withOutputDirectoryBuildLock<void>(outputDirectory, () async {
        throw failure;
      }),
      throwsA(same(failure)),
    );

    expect(
      await withOutputDirectoryBuildLock(outputDirectory, () async => 'next'),
      'next',
    );
    // On Windows this fails if the helper leaves the file handle open.
    await File.fromUri(
      outputDirectory.resolve('.flutter_rust_bridge_native_assets_build.lock'),
    ).delete();
  });

  test('different output directories can build concurrently', () async {
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    final first = withOutputDirectoryBuildLock(outputDirectory, () async {
      firstEntered.complete();
      await releaseFirst.future;
    });
    await firstEntered.future;

    try {
      expect(
        await withOutputDirectoryBuildLock(
          temporaryDirectory.uri.resolve('other/'),
          () async => 'independent',
        ).timeout(const Duration(seconds: 5)),
        'independent',
      );
    } finally {
      releaseFirst.complete();
      await first;
    }
  });

  test('separate processes wait for the OS lock', () async {
    final packageConfig = await Isolate.packageConfig;
    expect(packageConfig, isNotNull);
    final workerFile = File.fromUri(
      temporaryDirectory.uri.resolve('worker.dart'),
    );
    await workerFile.writeAsString('''
import 'dart:io';
import 'package:flutter_rust_bridge_hooks/src/build_lock.dart';

Future<void> main(List<String> args) async {
  stdout.writeln('waiting');
  await withOutputDirectoryBuildLock(Uri.parse(args.single), () async {
    stdout.writeln('locked');
    await stdin.first;
  });
  stdout.writeln('released');
}
''');

    Future<Process> startWorker() =>
        Process.start(Platform.resolvedExecutable, [
          '--packages=${packageConfig!.toFilePath()}',
          workerFile.path,
          outputDirectory.toString(),
        ]);

    final first = await startWorker();
    Process? second;
    StreamSubscription<String>? firstSubscription;
    StreamSubscription<String>? secondSubscription;
    final firstLocked = Completer<void>();
    final secondWaiting = Completer<void>();
    final secondLocked = Completer<void>();
    final firstErrors = first.stderr.transform(utf8.decoder).join();
    Future<String>? secondErrors;
    const timeout = Duration(seconds: 10);
    try {
      firstSubscription = first.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line == 'locked') firstLocked.complete();
          });
      await firstLocked.future.timeout(timeout);

      second = await startWorker();
      secondErrors = second.stderr.transform(utf8.decoder).join();
      secondSubscription = second.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (line == 'waiting') secondWaiting.complete();
            if (line == 'locked') secondLocked.complete();
          });
      await secondWaiting.future.timeout(timeout);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(secondLocked.isCompleted, isFalse);

      first.stdin.writeln('release');
      await first.stdin.flush();
      expect(
        await first.exitCode.timeout(timeout),
        0,
        reason: await firstErrors,
      );
      await secondLocked.future.timeout(timeout);
      second.stdin.writeln('release');
      await second.stdin.flush();
      expect(
        await second.exitCode.timeout(timeout),
        0,
        reason: await secondErrors,
      );
    } finally {
      first.kill();
      second?.kill();
      await first.exitCode;
      if (second != null) await second.exitCode;
      await firstSubscription?.cancel();
      await secondSubscription?.cancel();
      await firstErrors;
      if (secondErrors != null) await secondErrors;
    }
  });
}
