# Contributing to Mac Subsystem for Android (MSA)

Thank you for your interest in contributing to **Mac Subsystem for Android**! We welcome bug reports, feature requests, documentation improvements, and code contributions from the open-source community.

---

## Code of Conduct

This project is governed by our [Code of Conduct](CODE_OF_CONDUCT.md). By participating, you agree to abide by its terms.

---

## How Can I Contribute?

### Reporting Bugs
Before filing a bug report:
1. Check the [Issue Tracker](https://github.com/nikhilpatil12/mac-subsystem-android/issues) to ensure the issue hasn't already been reported.
2. Verify that you have installed the required dependencies (`xcode-select --install`, `brew install android-platform-tools`).
3. Include your macOS version, Mac hardware model (Apple Silicon M1/M2/M3/M4 or Intel), and detailed steps to reproduce.
4. Provide relevant output from:
   ```bash
   msa-cli status
   adb logcat -d | tail -n 50
   ```

### Suggesting Enhancements
Feature requests are welcomed! Please open an issue describing:
* The feature or improvement you would like to see.
* Why this feature is useful to MSA users.
* Potential implementation ideas or reference designs (e.g., Waydroid, WSA, UTM, Scrcpy).

### Submitting Pull Requests
1. **Fork** the repository and create your feature branch:
   ```bash
   git checkout -b feature/my-new-feature
   ```
2. **Make your changes**:
   * Adhere to Swift style conventions and Apple API guidelines.
   * Maintain clean separation between `MSACore` (framework), `MSACLI` (command line interface), and `msa-guest` (Linux VM assets).
   * Ensure any new features include appropriate tests.
3. **Build & Test**:
   ```bash
   make build
   make test
   ```
4. **Commit with clean, descriptive messages**:
   ```bash
   git commit -m "feat(ui): add support for multi-display window dragging"
   ```
5. **Push and submit your Pull Request** targeting the `main` branch.

---

## Local Development Workflow

### Requirements
* macOS 13.0 (Ventura) or newer (macOS Sonoma / Sequoia recommended).
* Xcode 15+ or Command Line Tools.
* Swift 5.9+ / 6.0 toolchain.
* Docker (only required if building custom guest rootfs or kernels from scratch).

### Useful Development Commands
```bash
# Build release binaries into build/bin/
make build

# Run unit tests
make test

# Format code and clean build artifacts
make clean
```
