# RitCode

**The terminal-native AI coding agent.** Any model. One static binary. A vintage-terminal-from-the-future you'll actually want to live in.

This repository distributes the compiled `ritcode` CLI: the install scripts and the prebuilt, checksum-verified binaries. RitCode itself is proprietary software (see [LICENSE](./LICENSE)); the source lives in a private repository and is not published here.

## Install

**macOS and Linux**
```sh
curl -fsSL https://raw.githubusercontent.com/ritiksharmma/ritcode-dist/main/install.sh | sh
```

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/ritiksharmma/ritcode-dist/main/install.ps1 | iex
```

The installer detects your platform, downloads the matching binary, verifies its SHA256 before trusting it, and installs to `~/.ritcode/bin` with no sudo. Then run `ritcode`.

## First run

RitCode asks once how you want to connect, and remembers it:
1. Paste an API key (Anthropic, or any OpenAI-compatible provider), or
2. Use a free local model through Ollama, with no key and no account.

A Claude Pro or ChatGPT Plus subscription is a different product from API access and will not work here; use an API key or the free local path.

## Commands

- `ritcode` opens the cockpit
- `ritcode --version` shows version, commit, target, and build date
- `ritcode update` checks for and installs a newer release (`--check-only`, `--yes`, `--rollback`, `--force`)
- `ritcode doctor` reports environment and install health
- `ritcode uninstall` removes it cleanly

RitCode also checks for a newer release at most once a day on startup and asks before updating. Turn that off with `RITCODE_NO_UPDATE_CHECK=1` or `[updates] check = false` in `.ritcode/config.toml`.

## Supported platforms

| OS | Architecture | Asset |
| --- | --- | --- |
| macOS | Apple silicon | `ritcode-<version>-aarch64-apple-darwin.tar.gz` |
| macOS | Intel | `ritcode-<version>-x86_64-apple-darwin.tar.gz` |
| Linux | x86_64 | `ritcode-<version>-x86_64-unknown-linux-gnu.tar.gz` |
| Linux | arm64 | `ritcode-<version>-aarch64-unknown-linux-gnu.tar.gz` |
| Windows | x86_64 | `ritcode-<version>-x86_64-pc-windows-msvc.zip` |

## Verifying your download

Every archive ships with a matching `.sha256`, and the installer checks it automatically. To verify by hand:
```sh
shasum -a 256 -c ritcode-<version>-<target>.tar.gz.sha256
```

## Known limitations

- **macOS:** binaries are not yet notarized. The installer clears the quarantine flag so first run works; codesigning is planned.
- **Windows on arm64** is not built yet.

## License

Proprietary. © 2026 Ritik Sharma. All rights reserved. The binaries distributed here are licensed for use, not for redistribution or reverse engineering. See [LICENSE](./LICENSE).
