# flutter_rust_bridge_hooks（OHOS 定制版）

为 Flutter Rust Bridge 项目提供 Native Assets build hook。包名保持为 `flutter_rust_bridge_hooks`，仓库目录是 `frb_hooks_ohos`；它委托同一仓库的 `native_toolchain_rust` 构建 Rust 库，包含 OHOS 支持和 Windows 短输出路径处理。

## 依赖配置

在应用根目录的 `pubspec.yaml` 添加或合并以下配置。使用 Pub workspace 时，覆盖配置必须放在消费工作区的根文件。

```yaml
dependencies:
  flutter_rust_bridge_hooks:
    git:
      url: https://github.com/star4277/native_toolchain_rust_ohos.git
      path: frb_hooks_ohos
      ref: main

dependency_overrides:
  hooks:
    git:
      url: https://gitcode.com/CPF-Flutter/fluttertpc_dart_native.git
      path: pkgs/hooks
      ref: flutter_3.47.7_deps
  code_assets:
    git:
      url: https://gitcode.com/CPF-Flutter/fluttertpc_dart_native.git
      path: pkgs/code_assets
      ref: flutter_3.47.7_deps
```

**当前不能省略根级 `dependency_overrides`。** 原定制 `code_assets` 仍引用 hosted 版 `hooks`，会与本包使用的 Git 版发生来源冲突。依赖包及本仓库根文件里的覆盖配置不会自动传递到消费项目；原定制仓库的传递依赖修复尚未发布。

无需另外直接声明 `hooks` 或 `native_toolchain_rust`：本包分别导出 hook API，并通过仓库内相对路径引用同一次 Git checkout 中的 Rust 构建器。包当前采用 Git 依赖方式使用，不能据其版本号改成同名 hosted 包。

已有 `pubspec.lock` 的项目更新本仓库代码时，可执行：

```powershell
fvm flutter pub upgrade flutter_rust_bridge_hooks native_toolchain_rust
```

## 添加 hook

先使用与项目 FRB runtime 匹配的生成器生成绑定。在应用的 `hook/build.dart` 中添加：

```dart
import 'package:flutter_rust_bridge_hooks/flutter_rust_bridge_hooks.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    await const FlutterRustBridgeNativeAssetsBuilder(
      assetName: 'src/rust/frb_generated.io.dart',
      cratePath: 'rust',
    ).run(input: input, output: output);
  });
}
```

`assetName` 相对于 `lib/`，必须与项目实际生成的 IO 绑定路径及其 native asset 标识匹配。改变 FRB 生成目录后，要同步修改这个值。`cratePath` 相对于应用包根目录。

此 hook 负责构建 Rust 库并注册 Native Assets，不执行 FRB 代码生成，也不创建 OHOS 应用工程。

## Rust 和 OHOS 环境

项目 crate（默认 `rust/`）必须具备：

- `Cargo.toml`：`[lib]` 的 `crate-type` 同时包含 `staticlib`、`cdylib`。
- `rust-toolchain.toml`：固定实际可安装的具体 Rust 版本，列出应用要构建的 OHOS targets；不能只写 `stable`、`beta` 或 `nightly`。
- 可用的 rustup、Rust 标准库及 native 编译工具。

配置示例、架构表和安装要求见根 [README 的 Rust 配置](../README.md#rust-crate-配置) 与 [OHOS SDK 配置](../README.md#ohos-sdk-配置)。

`OHOS_SDK_HOME` 在本库中必须指向包含 `llvm/`、`sysroot/` 的 native SDK 目录，例如 PowerShell：

```powershell
$env:OHOS_SDK_HOME = 'D:\Huawei\SDK\20\native'
fvm flutter pub get
fvm flutter build hap
```

设置永久环境变量后，请重启终端和 IDE。Flutter 自身还必须能发现 OHOS SDK 并向 hook 提供有效的 C 编译器配置。

**项目、SDK、Rust 工具链及临时目录的路径不要包含空格。** Windows 的 Cargo 产物会放入系统临时目录下的 `frb_native_assets_<hash>/`，所以也要检查该临时目录路径。

## 可配置选项

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `assetName` | `src/rust/frb_generated.io.dart` | 相对于 `lib/` 的生成绑定库路径 |
| `cratePath` | `rust` | 相对于应用根目录的 crate 路径 |
| `buildMode` | `FlutterRustBridgeBuildMode.release` | Rust 构建模式；需要调试 Rust 时显式设为 `debug`，不随 Flutter 模式自动切换 |
| `enableDefaultFeatures` | `true` | 是否启用 Cargo 默认 features |
| `features` | 空列表 | 额外启用的 Cargo features |
| `extraCargoBuildArgs` | 空列表 | 追加的 Cargo build 参数 |
| `extraCargoEnvironmentVariables` | 空映射 | 追加或覆盖 Cargo 环境变量；会覆盖同名平台默认参数 |
| `assetRouting` | `[ToAppBundle()]` | native asset 路由；OHOS 常规应用保持默认即可 |

## 平台识别和构建锁

- `OS.ohos` 输入直接构建 OHOS。
- 部分 SDK 用 `OS.linux` 表示 OHOS，本库会检查传入的 Clang 所属 native 目录是否存在 `build/cmake/ohos.toolchain.cmake`；存在才选择 OHOS，否则保持 Linux GNU target。
- `OHOS_SDK_HOME` 本身不决定平台。这一工具链推断无法区分“用 OHOS SDK Clang 构建真正 Linux”的情况，自定义 SDK 应正确传递 `OS.ohos`。
- 同一实际输出目录的构建会排队，并通过阻塞文件锁等待其他进程完成；不同输出目录可独立构建。构建异常后释放锁、关闭文件句柄。
- Windows 使用短临时输出目录。不要在构建进行时删除该目录；临时产物不能作为持久交付文件使用，最终产物由 Flutter 的 Native Assets 流程打包。

## 当前验证范围

本仓库共 44 个单元测试通过，已验证 FRB 配置、Windows 短路径、构建锁，以及 OHOS 三种架构的 C/C++ 编译和动态库链接。完整 FRB 代码生成、Rust 构建、HAP 打包和设备运行尚未验证，需在接入应用中继续验证。

FRB 本身的使用说明见 [fzyzcjy/flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge)；本仓库的定制依赖和 OHOS 接入以这里及根 README 为准。
