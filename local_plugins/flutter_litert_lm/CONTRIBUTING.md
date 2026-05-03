# Contributing to flutter_litert_lm

Thanks for your interest! This document describes how to set up a development
environment and the workflow for landing changes.

## Getting set up

```bash
git clone https://github.com/songhieu/flutter_litert_lm.git
cd flutter_litert_lm
flutter pub get
cd example && flutter pub get && cd ..
```

Run the example app on a device or emulator:

```bash
cd example
flutter run
```

For release-mode testing (which exercises R8 + the consumer-proguard-rules
the plugin ships):

```bash
cd example
flutter run --release
```

## Before you open a PR

CI runs the same three commands on every push. Run them locally first:

```bash
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
```

If you touched Kotlin code, build the example app's release APK to make sure
the Android side still compiles and the JNI bridge still resolves at runtime:

```bash
cd example
flutter build apk --release
```

## Coding conventions

- Match the style of the surrounding code. We use the standard `dart format`
  output — no exceptions.
- Public Dart APIs need dartdoc comments (`///`). Write them for the reader
  who will use the symbol, not for the person who wrote it.
- Don't add new dependencies casually. The plugin's `pubspec.yaml` is
  intentionally tiny.
- Don't introduce platform-specific code without a corresponding platform
  interface change.

## Updating LiteRT-LM

The plugin pins
`com.google.ai.edge.litertlm:litertlm-android:<version>` in
`android/build.gradle.kts`. When upstream ships a new release:

1. Bump the version in `android/build.gradle.kts`.
2. Verify the Kotlin bridge in `FlutterLitertLmPlugin.kt` still compiles —
   upstream sometimes renames classes or shifts default values between minor
   versions.
3. Run the example end-to-end with at least one model loaded on a real
   Android device. Loading the engine alone doesn't exercise the inference
   surface — actually send a message and check the streaming reply.
4. Add an entry to `CHANGELOG.md` under `## [Unreleased]` describing the
   bump and any API impact.

## Reporting issues

Please include:
- Plugin version
- Flutter version (`flutter --version`)
- Device model + Android version
- Backend (CPU / GPU / NPU) and model file you were running
- The full crash log from `adb logcat`, not just the Dart-side error

## License

By contributing you agree that your work is released under this project's
Apache 2.0 license.
