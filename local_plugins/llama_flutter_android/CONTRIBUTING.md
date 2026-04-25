# Contributing to llama_flutter_android

Thank you for your interest in contributing! This document provides guidelines and information for developers.

## Development Setup

### Prerequisites

- Flutter SDK 3.24.0+
- Android Studio or VS Code
- Android NDK r27+
- CMake 3.22.1+
- Git

### Initial Setup

1. Clone the repository:
\\\ash
git clone https://github.com/dragneel2074/llama_flutter_android.git
cd llama_flutter_android
\\\

2. Initialize submodules:
\\\ash
git submodule update --init --recursive
\\\

3. Install dependencies:
\\\ash
flutter pub get
\\\

## Project Structure

- \ndroid/\ - Native Android code (Kotlin + C++)
- \lib/\ - Dart code
- \pigeons/\ - Pigeon API definitions
- \example/\ - Example app
- \documentation/\ - Research and technical docs

## Development Workflow

### Phase 2: Pigeon API (Current)

1. Define API in \pigeons/llama_api.dart\
2. Generate code: \dart run pigeon --input pigeons/llama_api.dart\
3. Verify generated code compiles

### Phase 3: Kotlin Implementation

1. Implement plugin in \ndroid/src/main/kotlin/\
2. Write JNI wrapper in \ndroid/src/main/cpp/\
3. Build with: \cd android && ./gradlew build\

### Phase 4: Dart API

1. Create user-facing API in \lib/\
2. Add documentation comments
3. Run tests: \lutter test\

## Code Style

### Dart
- Follow [Effective Dart](https://dart.dev/guides/language/effective-dart)
- Use \lutter analyze\ before committing
- Format with: \dart format .\

### Kotlin
- Follow [Kotlin coding conventions](https://kotlinlang.org/docs/coding-conventions.html)
- Use ktlint for formatting
- 4-space indentation

### C++
- Follow llama.cpp style (for consistency)
- Use clang-format
- Modern C++17 practices

## Testing

### Unit Tests
\\\ash
flutter test
\\\

### Integration Tests
\\\ash
cd example
flutter test integration_test
\\\

### Android Tests
\\\ash
cd android
./gradlew test
\\\

## Submitting Changes

1. Fork the repository
2. Create a feature branch: \git checkout -b feature/my-feature\
3. Make your changes
4. Run tests
5. Commit with clear messages
6. Push and create a Pull Request

## Commit Messages

Follow [Conventional Commits](https://www.conventionalcommits.org/):

- \eat:\ New features
- \ix:\ Bug fixes
- \docs:\ Documentation changes
- \	est:\ Test additions/changes
- \efactor:\ Code refactoring
- \perf:\ Performance improvements

Examples:
\\\
feat: add token streaming support
fix: memory leak in model loading
docs: update API documentation
\\\

## Questions?

- Open an issue for bugs
- Start a discussion for questions
- Check existing issues first

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
