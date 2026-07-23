// Native assets build hook for bluez_native.
//
// Drives the project's CMake build to compile libbluez_nc.so, then declares
// the resulting shared library as a CodeAsset under the asset id
// `package:bluez_native/src/ffi/bluez_native_asset.dart`. Flutter apps bundle
// the .so automatically; `dart run` / `dart test` pick it up via the
// fallback loader in `lib/src/internal/library_loader.dart`.
//
// Patterned after https://github.com/meta-flutter/appstream_dart/blob/main/hook/build.dart

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;

    if (Platform.environment.containsKey('SKIP_NATIVE_BUILD')) {
      stderr.writeln('SKIP_NATIVE_BUILD set — skipping native build.');
      return;
    }

    final pkgRoot = input.packageRoot.toFilePath();
    final nativeRoot = '${pkgRoot}native';
    final buildDir = input.outputDirectory.resolve('cmake/').toFilePath();

    await Directory(buildDir).create(recursive: true);

    // `dart pub get` does not fetch git submodules, so consuming this package
    // as a git dependency leaves native/third_party/sdbus-cpp empty and CMake
    // has nothing to configure. Recover it when the checkout still has a .git;
    // pub.dev archives are unaffected because publishing bundles the submodule
    // contents as ordinary files.
    final sdbus = File('$nativeRoot/third_party/sdbus-cpp/CMakeLists.txt');
    if (!sdbus.existsSync()) {
      if (!Directory('$pkgRoot.git').existsSync() &&
          !File('$pkgRoot.git').existsSync()) {
        throw StateError(
          'native/third_party/sdbus-cpp is missing and $pkgRoot has no .git to '
          'restore it from. Clone with --recurse-submodules.',
        );
      }
      stderr.writeln('sdbus-cpp submodule missing; initializing');
      await _run('git', [
        '-C',
        pkgRoot,
        'submodule',
        'update',
        '--init',
        '--recursive',
      ]);
    }

    final hasNinja = await _which('ninja');

    if (!File('${buildDir}CMakeCache.txt').existsSync()) {
      await _run('cmake', [
        '-S',
        nativeRoot,
        '-B',
        buildDir,
        '-DCMAKE_BUILD_TYPE=Release',
        '-DBUILD_TESTING=OFF',
        '-DBLUEZ_HOOK_BUILD=ON',
        if (hasNinja) ...['-G', 'Ninja'],
      ]);
    }

    await _run('cmake', ['--build', buildDir, '--parallel']);

    final libFile = File('${buildDir}libbluez_nc.so');
    if (!libFile.existsSync()) {
      throw StateError('libbluez_nc.so not found at ${libFile.path}');
    }

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/ffi/bluez_native_asset.dart',
        linkMode: DynamicLoadingBundled(),
        file: libFile.uri,
      ),
    );

    // Re-run the hook whenever any C/C++ source or CMake file changes.
    for (final dir in ['src', 'include']) {
      final d = Directory('$nativeRoot/$dir');
      if (!d.existsSync()) continue;
      for (final entity in d.listSync(recursive: true)) {
        if (entity is! File) continue;
        final p = entity.path;
        if (p.endsWith('.cpp') ||
            p.endsWith('.cc') ||
            p.endsWith('.c') ||
            p.endsWith('.hpp') ||
            p.endsWith('.h')) {
          output.dependencies.add(entity.uri);
        }
      }
    }
    output.dependencies.add(Uri.file('$nativeRoot/CMakeLists.txt'));

    stderr.writeln('libbluez_nc built: ${libFile.path}');
  });
}

Future<void> _run(String exe, List<String> args) async {
  final p = await Process.start(exe, args, mode: ProcessStartMode.inheritStdio);
  final code = await p.exitCode;
  if (code != 0) {
    throw ProcessException(exe, args, 'exit code $code', code);
  }
}

Future<bool> _which(String exe) async {
  final r = await Process.run('which', [exe]);
  return r.exitCode == 0;
}
