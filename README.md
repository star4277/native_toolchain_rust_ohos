# native_toolchain_rust_ohos

基于 [GregoryConrad/native_toolchain_rust](https://github.com/GregoryConrad/native_toolchain_rust) 的 OHOS 定制版本，通过 Dart/Flutter build hooks 构建 Rust 库并注册 Native Assets。本仓库同时提供 Flutter Rust Bridge 的 hook 封装。

| 包名 | 仓库内目录 | 用途 |
| --- | --- | --- |
| `native_toolchain_rust` | `native_toolchain_rust` | 通用 Rust 构建器，包含 OHOS 目标和编译环境支持 |
| `flutter_rust_bridge_hooks` | `frb_hooks_ohos` | FRB 项目的 hook 封装，委托上述构建器构建 Rust 库 |

FRB 项目请阅读 [flutter_rust_bridge_hooks 接入说明](frb_hooks_ohos/README.md)，其中包含可以复制的依赖和 hook 配置。

## 使用前提

- 使用支持 OHOS Native Assets 的定制 Flutter SDK。当前验证环境为 Flutter `3.47.7+ohos-0.0.1-pre`、Dart `3.13.5`；定制依赖分支为 `flutter_3.47.7_deps`。
- 安装 Git、rustup 和 OHOS native SDK，并保证 Git 仓库可访问。
- 定制依赖要求 Dart `>=3.10.0 <4.0.0`。用 `fvm flutter --version` 确认 FVM 实际选择的是所需的 OHOS SDK。
- Rust crate 中必须有 `Cargo.toml` 和 `rust-toolchain.toml`，并在工具链文件中固定具体 Rust 版本及所需 target。
- 项目、SDK、Rust 工具链及临时目录的路径不要包含空格。当前编译参数采用空格分隔，没有完整处理带空格的路径。

## 在外部项目中依赖本仓库

在应用根目录的 `pubspec.yaml` 中添加：

```yaml
dependencies:
  native_toolchain_rust:
    git:
      url: https://github.com/star4277/native_toolchain_rust_ohos.git
      path: native_toolchain_rust
      ref: main
  hooks:
    git:
      url: https://gitcode.com/CPF-Flutter/fluttertpc_dart_native.git
      path: pkgs/hooks
      ref: flutter_3.47.7_deps

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

**当前外部项目仍需要上述根级 `dependency_overrides`。** 原定制 `code_assets` 的 manifest 仍引用 hosted 版 `hooks`，而本库使用 Git 定制版 `hooks`，两种来源会发生冲突。Pub 只采用消费项目根目录的覆盖配置；本仓库的覆盖配置不会自动传给依赖本仓库的应用。使用 Pub workspace 时，将覆盖配置放在消费工作区的根 `pubspec.yaml`。

如果应用已有这些配置，请合并到同一个 `dependencies` / `dependency_overrides` 节点，不要创建重复 YAML 键。不要将这些定制依赖替换为官方 hosted 包。原定制仓库的传递依赖修复尚未发布，因此当前不能省略覆盖配置。

如果应用还使用定制版 `ffigen`，也需要将 `native_toolchain_c` 覆盖到同一 Git 地址、`pkgs/native_toolchain_c` 路径和 `flutter_3.47.7_deps` 分支。该分支的 `ffigen` 为 21 系列；本仓库的示例已按其 API 调整。Melos 版本限制只用于本仓库开发，并非普通消费项目的必装依赖。

`ref: main` 跟随本仓库主分支。需要固定构建版本时，可以将本仓库依赖的 ref 固定为经过验证的提交 SHA，并保留应用的 `pubspec.lock`。

## Rust crate 配置

例如项目采用 `rust/` 目录：

```toml
# rust/Cargo.toml
[package]
name = "my_rust_library"
version = "0.1.0"
edition = "2024"

[lib]
crate-type = ["staticlib", "cdylib"]
```

将下面的工具链配置放在 **crate 目录内**。构建器会读取 `rust/rust-toolchain.toml`，不会自动用应用根目录的同名文件替代它。

```toml
# rust/rust-toolchain.toml
[toolchain]
channel = "1.99.0"
targets = [
  "aarch64-unknown-linux-ohos",
  "x86_64-unknown-linux-ohos",
  "armv7-unknown-linux-ohos",
]
```

`1.99.0` 是本仓库当前固定版本；消费项目应选择实际可安装、支持所需目标的具体版本。不能只写 `stable`、`beta` 或 `nightly`，构建器会拒绝这些未固定的 channel。只启用所需的 targets，并确认该版本提供对应目标的 Rust 标准库；目标未提供 rustup 组件时，需要自行准备支持它的工具链，本库不会自动构建标准库。

本仓库两个示例的 crate 工具链文件是指向根 `rust-toolchain.toml` 的符号链接。外部应用可以使用独立文件，无需复制这一符号链接结构。

## 添加 build hook

在应用的 `hook/build.dart` 中添加：

```dart
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_rust/native_toolchain_rust.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    await const RustBuilder(
      assetName: 'src/my_ffi_bindings.g.dart',
      cratePath: 'rust',
    ).run(input: input, output: output);
  });
}
```

`assetName` 是相对于 `lib/` 的绑定库路径，必须与实际使用该 native asset 的生成绑定匹配。本 hook 负责构建和注册库，不负责生成 Dart FFI/FRB 绑定。

## OHOS SDK 配置

本构建器将 `OHOS_SDK_HOME` 解释为 **native SDK 目录**，其中应包含：

```text
native/
  llvm/bin/clang[.exe]
  llvm/bin/clang++[.exe]
  llvm/bin/llvm-ar[.exe]
  llvm/bin/llvm-ranlib[.exe]
  build/cmake/ohos.toolchain.cmake
  sysroot/
```

Windows PowerShell 当前会话配置示例：

```powershell
$env:OHOS_SDK_HOME = 'D:\Huawei\SDK\20\native'
fvm flutter pub get
```

如果在系统环境变量界面设置，请重启终端、IDE 以及启动构建的进程，使其继承新值。Flutter/DevEco 自身的 SDK 发现配置也需要正确；本变量的上述目录约定用于本库的编译参数，不能替代 Flutter 提供有效的 `CCompilerConfig`。

构建器为 Rust linker、C/C++ 编译和 bindgen 配置对应的 target、sysroot、架构头文件目录及工具路径。通过 CMake 构建的 Rust 依赖可能还需要在其自身配置中传入 `build/cmake/ohos.toolchain.cmake`，CFLAGS 等变量不能替代所有第三方构建系统的配置。

| Dart 架构 | Rust target | Clang target |
| --- | --- | --- |
| `arm64` | `aarch64-unknown-linux-ohos` | `aarch64-linux-ohos` |
| `x64` | `x86_64-unknown-linux-ohos` | `x86_64-linux-ohos` |
| `arm` | `armv7-unknown-linux-ohos` | `arm-linux-ohos` |

## 平台兼容判断

某些定制 Flutter SDK 在 OHOS 构建时给 hook 传入 `OS.linux`，同时提供 OHOS SDK 的编译器路径。本库兼容两种输入：

1. 输入为 `OS.ohos` 时，直接选择 OHOS target。
2. 输入为 `OS.linux` 时，从 `cCompiler.compiler` 的 `native/llvm/bin/clang` 路径向上查找 native 目录；若其中存在 `build/cmake/ohos.toolchain.cmake`，选择 OHOS target，否则保留 Linux GNU target。

**设置 `OHOS_SDK_HOME` 不会单独触发 OHOS 平台识别。** 这是根据传入工具链进行的兼容推断：使用 OHOS SDK Clang 构建真正的 Linux 时，也会被识别为 OHOS。自定义 SDK 应优先正确传入 `OS.ohos`。

## 构建与更新依赖

```powershell
fvm flutter pub get
fvm flutter build hap
```

HAP 构建命令由所使用的定制 Flutter SDK 提供，需要应用已配置 OHOS 工程。更新本仓库代码时，已有 lockfile 可能继续使用旧 Git 提交，可执行针对性升级：

```powershell
fvm flutter pub upgrade native_toolchain_rust
```

出现 `hooks from hosted` 与 `hooks from git` 冲突时，先检查消费项目根级依赖覆盖。出现缺少 `CCompilerConfig` 或 SDK native path 错误时，分别检查 Flutter 的 SDK 发现配置和构建进程中的 `OHOS_SDK_HOME`。

## 当前验证范围

- 44 个单元测试通过，覆盖 Rust 工具链辅助逻辑、OHOS 平台兼容、FRB 配置及构建锁。
- 已在 Windows 主机上用 OHOS SDK 验证 arm64、x64、armv7 的 C/C++ 编译和 `.so` 链接。
- 构建锁已验证同一 isolate 内排队、跨进程等待及异常后的再次获取。
- 静态检查没有 Dart 代码错误；定制 Git/path 依赖仍会产生发布配置警告。本仓库当前按 Git 依赖方式使用。
- 完整 FRB 代码生成、Rust crate 到 HAP 的构建及设备运行尚未验证；接入后仍需针对应用实际依赖做完整构建测试。

## 上游与许可证

- Rust 构建器上游：[GregoryConrad/native_toolchain_rust](https://github.com/GregoryConrad/native_toolchain_rust)。
- FRB hook 上游：[fzyzcjy/flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge)。
- 许可证见根目录 [LICENSE](LICENSE) 和 [frb_hooks_ohos/LICENSE](frb_hooks_ohos/LICENSE)。
