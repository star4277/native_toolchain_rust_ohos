import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/src/build_environment.dart';
import 'package:native_toolchain_rust/src/config_mapping.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory sdk;
  late CCompilerConfig ohosCompiler;

  setUp(() {
    sdk = Directory.systemTemp.createTempSync('rust_ohos_');
    final toolchain = File(
      path.join(sdk.path, 'build', 'cmake', 'ohos.toolchain.cmake'),
    );
    toolchain.parent.createSync(recursive: true);
    toolchain.writeAsStringSync('');
    final exe = Platform.isWindows ? '.exe' : '';
    final binDir = path.join(sdk.path, 'llvm', 'bin');
    ohosCompiler = CCompilerConfig(
      compiler: path.toUri(path.join(binDir, 'clang$exe')),
      archiver: path.toUri(path.join(binDir, 'llvm-ar$exe')),
      linker: path.toUri(path.join(binDir, 'ld.lld$exe')),
    );
  });

  tearDown(() => sdk.deleteSync(recursive: true));

  CodeConfig config(
    OS os,
    Architecture architecture, {
    CCompilerConfig? compiler,
  }) {
    final builder = BuildInputBuilder()
      ..setupShared(
        packageName: 'test_package',
        packageRoot: sdk.uri,
        outputFile: sdk.uri.resolve('output.json'),
        outputDirectoryShared: sdk.uri,
      )
      ..config.setupBuild(linkingEnabled: false)
      ..addExtension(
        CodeAssetExtension(
          targetOS: os,
          targetArchitecture: architecture,
          linkModePreference: LinkModePreference.dynamic,
          cCompiler: compiler,
        ),
      );
    return builder.build().config.code;
  }

  const targets = [
    (
      arch: Architecture.arm64,
      rust: 'aarch64-unknown-linux-ohos',
      clang: 'aarch64-linux-ohos',
    ),
    (
      arch: Architecture.x64,
      rust: 'x86_64-unknown-linux-ohos',
      clang: 'x86_64-linux-ohos',
    ),
    (
      arch: Architecture.arm,
      rust: 'armv7-unknown-linux-ohos',
      clang: 'arm-linux-ohos',
    ),
  ];

  for (final target in targets) {
    test('OHOS ${target.arch} supports both SDK platform representations', () {
      final ohos = config(OS.ohos, target.arch, compiler: ohosCompiler);
      final compatibility = config(
        OS.linux,
        target.arch,
        compiler: ohosCompiler,
      );
      expect(ohos.rustTargetOS, OS.ohos);
      expect(compatibility.rustTargetOS, OS.ohos);
      expect(ohos.targetTriple, target.rust);
      expect(compatibility.targetTriple, ohos.targetTriple);

      final factory = OhosBuildEnvironmentFactory(
        environment: {'OHOS_SDK_HOME': sdk.path},
      );
      expect(
        factory.createBuildEnvVars(codeConfig: compatibility),
        factory.createBuildEnvVars(codeConfig: ohos),
      );
    });

    test(
      'OHOS ${target.arch} configures Rust, C++, and bindgen for the SDK',
      () {
        final env =
            OhosBuildEnvironmentFactory(
              environment: {'OHOS_SDK_HOME': sdk.path},
            ).createBuildEnvVars(
              codeConfig: config(OS.ohos, target.arch, compiler: ohosCompiler),
            );
        final targetEnv = target.rust.replaceAll('-', '_');
        final binDir = path.dirname(path.fromUri(ohosCompiler.compiler));
        final exe = Platform.isWindows ? '.exe' : '';
        final flags = env['CFLAGS_$targetEnv']!;
        expect(env['CC_$targetEnv'], path.fromUri(ohosCompiler.compiler));
        expect(env['CXX_$targetEnv'], path.join(binDir, 'clang++$exe'));
        expect(env['AR_$targetEnv'], path.fromUri(ohosCompiler.archiver));
        expect(env['RANLIB_$targetEnv'], path.join(binDir, 'llvm-ranlib$exe'));
        expect(flags, contains('--target=${target.clang}'));
        expect(
          flags,
          contains(
            '--sysroot=${path.join(sdk.path, 'sysroot').replaceAll(r'\', '/')}',
          ),
        );
        expect(flags, contains('/sysroot/usr/include/${target.clang}'));
        expect(flags, contains('-D__MUSL__'));
        expect(
          flags.contains('-march=armv7a'),
          target.arch == Architecture.arm,
        );
        expect(flags, isNot(contains(r'\')));
        expect(env['CXXFLAGS_$targetEnv'], flags);
        expect(env['BINDGEN_EXTRA_CLANG_ARGS_$targetEnv'], flags);
        expect(
          env['CARGO_TARGET_${targetEnv.toUpperCase()}_LINKER'],
          env['CC_$targetEnv'],
        );
        final rustFlags =
            env['CARGO_TARGET_${targetEnv.toUpperCase()}_RUSTFLAGS']!;
        expect(rustFlags, contains('link-arg=--target=${target.clang}'));
        expect(rustFlags, contains('link-arg=-fuse-ld=lld'));
        expect(rustFlags, isNot(contains('-D__MUSL__')));
      },
    );
  }

  test('Linux without an OHOS compiler keeps GNU targets', () {
    for (final target in [
      (arch: Architecture.arm64, rust: 'aarch64-unknown-linux-gnu'),
      (arch: Architecture.x64, rust: 'x86_64-unknown-linux-gnu'),
    ]) {
      final linux = config(OS.linux, target.arch);
      expect(linux.rustTargetOS, OS.linux);
      expect(linux.targetTriple, target.rust);
      final env = const BuildEnvironmentFactory().createBuildEnvVars(linux);
      expect(env.keys.where((key) => key.startsWith('CARGO_TARGET_')), isEmpty);
      expect(env.keys.where((key) => key.startsWith('CC_')), isEmpty);
    }
  });

  test('Linux compiler outside the OHOS SDK keeps its Linux target', () {
    final binDir = path.join(sdk.path, 'host', 'llvm', 'bin');
    final hostCompiler = CCompilerConfig(
      compiler: path.toUri(path.join(binDir, 'clang')),
      linker: path.toUri(path.join(binDir, 'ld')),
      archiver: path.toUri(path.join(binDir, 'ar')),
    );
    final linux = config(OS.linux, Architecture.x64, compiler: hostCompiler);
    expect(linux.rustTargetOS, OS.linux);
    expect(linux.targetTriple, 'x86_64-unknown-linux-gnu');
  });

  test('Windows target keeps its platform even with an OHOS compiler', () {
    final windows = config(
      OS.windows,
      Architecture.x64,
      compiler: ohosCompiler,
    );
    expect(windows.rustTargetOS, OS.windows);
    expect(windows.targetTriple, 'x86_64-pc-windows-msvc');
  });

  test('OHOS environment rejects a regular Linux target', () {
    expect(
      () =>
          OhosBuildEnvironmentFactory(
            environment: {'OHOS_SDK_HOME': sdk.path},
          ).createBuildEnvVars(
            codeConfig: config(
              OS.linux,
              Architecture.x64,
              compiler: CCompilerConfig(
                compiler: sdk.uri.resolve('host/llvm/bin/clang'),
                linker: sdk.uri.resolve('host/llvm/bin/ld'),
                archiver: sdk.uri.resolve('host/llvm/bin/ar'),
              ),
            ),
          ),
      throwsUnsupportedError,
    );
  });

  test('OHOS environment reports missing SDK configuration', () {
    expect(
      () =>
          const OhosBuildEnvironmentFactory(environment: {}).createBuildEnvVars(
            codeConfig: config(
              OS.ohos,
              Architecture.arm64,
              compiler: ohosCompiler,
            ),
          ),
      throwsUnsupportedError,
    );
  });
}
