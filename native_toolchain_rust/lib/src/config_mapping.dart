import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;

@internal
extension CodeConfigMapping on CodeConfig {
  OS get rustTargetOS {
    if (targetOS != OS.linux) return targetOS;

    final compiler = cCompiler?.compiler;
    if (compiler == null) return OS.linux;

    // Some OHOS SDKs pass Linux to hooks, but still supply the OHOS compiler.
    // Identify its native SDK directory without changing regular Linux builds.
    final nativeRoot = path.dirname(
      path.dirname(path.dirname(path.fromUri(compiler))),
    );
    final toolchainFile = path.join(
      nativeRoot,
      'build',
      'cmake',
      'ohos.toolchain.cmake',
    );
    return File(toolchainFile).existsSync() ? OS.ohos : OS.linux;
  }

  String get targetTriple {
    return switch ((rustTargetOS, targetArchitecture)) {
      // Android
      (OS.android, Architecture.arm64) => 'aarch64-linux-android',
      (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
      (OS.android, Architecture.x64) => 'x86_64-linux-android',

      // iOS
      (OS.iOS, Architecture.arm64)
          when iOS.targetSdk == IOSSdk.iPhoneSimulator =>
        'aarch64-apple-ios-sim',
      (OS.iOS, Architecture.arm64) when iOS.targetSdk == IOSSdk.iPhoneOS =>
        'aarch64-apple-ios',
      (OS.iOS, Architecture.arm64) => throw UnsupportedError(
        'Unknown IOSSdk: ${iOS.targetSdk}',
      ),
      (OS.iOS, Architecture.x64) => 'x86_64-apple-ios',

      // Windows
      (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
      (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',

      // Linux
      (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
      (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',

      // macOS
      (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
      (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',

      // ohos
      (OS.ohos, Architecture.arm64) => 'aarch64-unknown-linux-ohos',
      (OS.ohos, Architecture.x64) => 'x86_64-unknown-linux-ohos',
      (OS.ohos, Architecture.arm) => 'armv7-unknown-linux-ohos',

      (_, _) => throw UnsupportedError(
        'Unsupported target: $rustTargetOS on $targetArchitecture',
      ),
    };
  }

  LinkMode get linkMode {
    return switch (linkModePreference) {
      LinkModePreference.dynamic ||
      LinkModePreference.preferDynamic => DynamicLoadingBundled(),
      LinkModePreference.static ||
      LinkModePreference.preferStatic => StaticLinking(),
      _ => throw UnsupportedError(
        'Unsupported LinkModePreference: $linkModePreference',
      ),
    };
  }
}
