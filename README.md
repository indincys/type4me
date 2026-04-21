# Type4Me Cloud

Type4Me Cloud is a cloud-only macOS voice input app derived from Type4Me. This fork keeps the cloud ASR and LLM workflow and removes the bundled local ASR model distribution path.

## What This Version Includes

- Cloud ASR providers such as Volcano, Soniox, Deepgram, AssemblyAI, Baidu, Bailian, OpenAI-compatible services, and Apple Speech.
- LLM post-processing providers for polishing, translation, prompt optimization, and custom modes.
- Hotwords, snippet replacement, history, export, global hotkeys, and clipboard-based text injection.
- A redesigned macOS Liquid Glass floating transcription window.
- Cloud-only DMG packaging for Intel and Apple Silicon Macs.

## What This Version Does Not Include

- Bundled SenseVoice / Qwen3 ASR models.
- Local ASR server packaging.
- Local-model DMG release automation.

The generated DMG should stay small because model files and build artifacts are not committed or bundled.

## Requirements

- macOS 14 or newer.
- Xcode 26 / Swift 6.2 for local development.
- API keys for the cloud ASR and LLM providers you choose.

## Local Development

Run the full test suite:

```bash
swift test
```

Build a cloud-only DMG:

```bash
APP_VERSION=1.9.2 bash scripts/build-dmg.sh
```

The output is written to `dist/Type4Me-v<version>-cloud.dmg`.

## CI/CD

This repository includes GitHub Actions workflows:

- `CI`: runs on every push and pull request, executes the full Swift test suite, and uploads a short-lived cloud DMG artifact.
- `Build and Release DMG`: creates a GitHub Release with a cloud-only DMG.

To publish a release without using the command line:

1. Open the repository on GitHub.
2. Go to `Actions`.
3. Choose `Build and Release DMG`.
4. Click `Run workflow`.
5. Enter a version such as `1.9.3`.

The workflow will run tests, build the DMG, verify it, create tag `v<version>`, and attach the DMG to a GitHub Release.

To publish from the command line:

```bash
git tag v1.9.3
git push origin v1.9.3
```

## Packaging Notes

The scripts intentionally build only the cloud edition:

- `scripts/package-app.sh`
- `scripts/build-dmg.sh`

They do not copy model files, local ASR servers, or large generated artifacts.
