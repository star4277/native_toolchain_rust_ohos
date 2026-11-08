import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:meta/meta.dart';
import 'package:native_toolchain_rust/src/config_mapping.dart';
import 'package:native_toolchain_rust/src/exception.dart';
import 'package:path/path.dart' as path;

@internal
interface class BuildEnvironmentFactory {
  const BuildEnvironmentFactory();

  Map<String, String> createBuildEnvVars(CodeConfig codeConfig) {
    return {
      // NOTE: XCode makes some injections into PATH that break host build
      // for crates with a build.rs
      // See also: https://github.com/irondash/native_toolchain_rust/issues/17
      if (Platform.isMacOS) ...{
        'PATH': Platform.environment['PATH']!
            .split(':')
            .where((e) => !e.contains('Contents/Developer/'))
            .join(':'),
      },

      if (codeConfig.rustTargetOS == OS.ohos)
        ...const OhosBuildEnvironmentFactory().createBuildEnvVars(
          codeConfig: codeConfig,
        ),

      if (codeConfig.targetOS == OS.android)
        ...const AndroidBuildEnvironmentFactory().createBuildEnvVars(
          codeConfig: codeConfig,
        ),
    };
  }
}

@internal
interface class AndroidBuildEnvironmentFactory {
  const AndroidBuildEnvironmentFactory();

  Map<String, String> createBuildEnvVars({required CodeConfig codeConfig}) {
    final CodeConfig(:targetTriple, :cCompiler) = codeConfig;
    if (cCompiler == null) {
      throw UnsupportedError(
        'CCompilerConfig was not provided but is required for $targetTriple',
      );
    }

    String getBinaryPath(String binaryName, {String windowsSuffix = 'cmd'}) {
      final compilerBinariesDir = path.dirname(
        path.fromUri(cCompiler.compiler),
      );
      final binaryPath = path.join(
        compilerBinariesDir,
        (OS.current == OS.windows) ? '$binaryName.$windowsSuffix' : binaryName,
      );

      if (!File(binaryPath).existsSync()) {
        throw RustValidationException([
          'Binary $binaryPath not found; is your installed NDK too old?',
        ]);
      }

      return binaryPath;
    }

    final targetTripleEnvVar = targetTriple.replaceAll('-', '_');
    final ndkTargetTriple = switch (targetTriple) {
      // NOTE: sometimes the Rust and NDK target triples do not match.
      // See: https://github.com/GregoryConrad/native_toolchain_rust/issues/21#issuecomment-3368307228
      'armv7-linux-androideabi' => 'armv7a-linux-androideabi',
      _ => targetTriple,
    };
    final ndkSysrootTargetTriple = switch (targetTriple) {
      // NOTE: sometimes the Rust and NDK sysroot target triples do not match.
      'armv7-linux-androideabi' => 'arm-linux-androideabi',
      _ => targetTriple,
    };

    // NOTE: we need to point to NDK >=27 vended LLVM for Android.
    // The `${ndkTargetTriple}35-clang`s were introduced in NDK 27,
    // so using these binaries:
    // 1. Ensures we are using a compatible NDK
    // 2. Also fixes build issues when just using the `clang`s directly
    const apiTarget = '35';
    final clangPath = getBinaryPath('$ndkTargetTriple$apiTarget-clang');
    final clangPpPath = getBinaryPath('$ndkTargetTriple$apiTarget-clang++');
    final ranlibPath = getBinaryPath('llvm-ranlib', windowsSuffix: 'exe');

    final ndkToolchainRoot = path.dirname(path.dirname(clangPath));
    final sysroot = path.join(ndkToolchainRoot, 'sysroot');
    final extraInclude = '$sysroot/usr/include/$ndkSysrootTargetTriple';
    final bindgenClangArgs = '--sysroot=$sysroot -I$extraInclude'
        // NOTE: force the use of forward-slash path separators
        .replaceAll(r'\', '/');

    return {
      'AR_$targetTripleEnvVar': path.fromUri(cCompiler.archiver),
      'CC_$targetTripleEnvVar': clangPath,
      'CXX_$targetTripleEnvVar': clangPpPath,
      'RANLIB_$targetTripleEnvVar': ranlibPath,
      'CARGO_TARGET_${targetTripleEnvVar.toUpperCase()}_LINKER': clangPath,
      'BINDGEN_EXTRA_CLANG_ARGS_$targetTripleEnvVar': bindgenClangArgs,
    };
  }
}

@internal
interface class OhosBuildEnvironmentFactory {
  const OhosBuildEnvironmentFactory({this.environment});

  final Map<String, String>? environment;

  Map<String, String> createBuildEnvVars({required CodeConfig codeConfig}) {
    final CodeConfig(:targetTriple, :cCompiler) = codeConfig;
    if (cCompiler == null) {
      throw UnsupportedError(
        'CCompilerConfig was not provided but is required for $targetTriple',
      );
    }
    final sdkPath = (environment ?? Platform.environment)['OHOS_SDK_HOME'];
    if (sdkPath == null || sdkPath.isEmpty) {
      throw UnsupportedError('OHOS SDK native path is not set');
    }
    final exe = Platform.isWindows ? '.exe' : '';
    final binDir = path.join(sdkPath, 'llvm', 'bin');
    final clangPath = path.join(binDir, 'clang$exe');
    final sysroot = path.join(sdkPath, 'sysroot');
    final clangTarget = switch (targetTriple) {
      'aarch64-unknown-linux-ohos' => 'aarch64-linux-ohos',
      'armv7-unknown-linux-ohos' => 'arm-linux-ohos',
      'x86_64-unknown-linux-ohos' => 'x86_64-linux-ohos',

      _ => throw UnsupportedError('Unsupported OHOS target: $targetTriple'),
    };

    final targetEnv = targetTriple.replaceAll('-', '_');
    final linkerEnvVar = 'CARGO_TARGET_${targetEnv.toUpperCase()}_LINKER';
    final rustFlagsEnvVar = 'CARGO_TARGET_${targetEnv.toUpperCase()}_RUSTFLAGS';
    // bindgen uses shell quoting; avoid Windows backslashes in its arguments.
    final sysrootArg = sysroot.replaceAll(r'\', '/');
    final includeDir = path
        .join(sysroot, 'usr', 'include', clangTarget)
        .replaceAll(r'\', '/');
    final clangFlags = [
      '--target=$clangTarget',
      '--sysroot=$sysrootArg',
      '-I$includeDir',
      '-D__MUSL__',
      if (codeConfig.targetArchitecture == Architecture.arm) '-march=armv7a',
    ].join(' ');
    final rustFlags =
        '-C link-arg=--target=$clangTarget '
        '-C link-arg=-fuse-ld=lld '
        '-C link-arg=--sysroot=$sysrootArg';
    return {
      rustFlagsEnvVar: rustFlags,
      linkerEnvVar: clangPath,
      'CC_$targetEnv': clangPath,
      'CXX_$targetEnv': path.join(binDir, 'clang++$exe'),
      'AR_$targetEnv': path.join(binDir, 'llvm-ar$exe'),
      'RANLIB_$targetEnv': path.join(binDir, 'llvm-ranlib$exe'),
      'CFLAGS_$targetEnv': clangFlags,
      'CXXFLAGS_$targetEnv': clangFlags,
      'BINDGEN_EXTRA_CLANG_ARGS_$targetEnv': clangFlags,
    };
  }
}
