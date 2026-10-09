+++
title = "Platform Support"
description = "Which operating systems and architectures gori supports, what each support tier promises, and the known gaps on Windows."
weight = 7
+++

gori ships as one binary for macOS, Linux and Windows, but not every platform gets the same guarantees. They are sorted into two tiers. A platform is named by its OS and CPU architecture, the way release assets are named (`linux-arm64`, `osx-x86_64`). gori is built with Crystal, so each platform also depends on the compiler's own [platform support](https://crystal-lang.org/reference/1.21/syntax_and_semantics/platform_support.html).

## Tier 1 {#tier-1}

Tier 1 platforms can be thought of as "the whole of gori". Each one:

- gets a pre-built binary on every [GitHub Release](https://github.com/hahwul/gori/releases/latest) and is covered by the [curl installer](/getting-started/installation/#quick-install-curl) and [Homebrew](/getting-started/installation/#homebrew),
- is built from source in CI or at release, and its release binary is run before it is published,
- is used day to day: macOS is the platform gori is developed on, and the spec suite runs on Linux x86_64 in CI (the specs mirroring a change on every pull request, the full suite on every push to `main`),
- has no known platform-specific gaps.

| Target | Release asset | Other channels | Tested by |
|--------|---------------|----------------|-----------|
| macOS arm64 (Apple Silicon) | `gori-v*-osx-arm64.tar.gz` | Nix | Day-to-day development; the release build runs `--version` from its packaged tarball |
| macOS x86_64 (Intel) | `gori-v*-osx-x86_64.tar.gz` | — | The release build runs `--version` from its packaged tarball |
| Linux x86_64 | `gori-v*-linux-x86_64` (static, musl) | AUR, Snap, Nix, Docker | The specs mirroring a change on every pull request, the full suite on every push to `main`; the release binary is checked to be static and run |
| Linux arm64 | `gori-v*-linux-arm64` (static, musl) | Nix, Docker | The Docker image is built natively on every push to `main`; the release binary is checked to be static and run |

The spec suite does not run on macOS or Linux arm64 in CI, so a regression specific to one of those targets is found in use, not by CI.

## Tier 2 {#tier-2}

Tier 2 platforms can be thought of as "works, with known gaps". Each one builds and passes its own CI, ships release binaries, but may have known gaps, listed below.

| Target | Release asset | Other channels | Tested by |
|--------|---------------|----------------|-----------|
| Windows x86_64 | `gori-v*-windows-x86_64.exe` (static) | Chocolatey | On every pull request that touches Crystal code: a native build, a smoke test that proxies an HTTP and an HTTPS request and reads them back from the project, the TUI driven under a real Windows pseudo-console (ConPTY), and the spec suite, one file at a time |

Release binaries for Windows start with v0.8.0.

### Windows known gaps {#windows-gaps}

| Area | On Windows |
|------|------------|
| Console | The TUI needs a console that speaks VT sequences: Windows Terminal, or any Windows 10 1809+ console. |
| Signals | There are no POSIX signals. Ctrl-C and Ctrl-Break act as `INT`; closing the console window, logging off or shutting down act as `TERM`, but Windows ends the process soon after, so cleanup on those gets little time. |
| [`gori run shell`](/reference/cli/#run-shell) | The CA bundle it writes starts from the system roots, which gori looks for only at Unix paths. On Windows it holds gori's root alone unless `SSL_CERT_FILE` already names a bundle, so a tool in that shell fails TLS verification for any host gori does not intercept (a passthrough host, anything in `NO_PROXY`). Export a full bundle as `SSL_CERT_FILE` first to avoid it. The default `--print` syntax there is PowerShell. |
| File permissions | POSIX modes such as `0600` on the root CA key do not apply. Files under `GORI_HOME` (`%USERPROFILE%\.gori`) get whatever access that folder grants. |
| `gori update` | Windows will not overwrite a running `.exe`, so the old one is renamed aside and the new one takes its place; if the old one is still running, the leftover `.gori-update.old.*` file is removed by the next `gori update`. A Chocolatey install is never updated in place: `gori update` prints `choco upgrade gori -y`, to run from an elevated shell with gori closed. |
| Installer | The curl installer is macOS and Linux only. Use [Chocolatey](/getting-started/installation/#chocolatey-windows) or the [direct download](/getting-started/installation/#windows). |
| [Messages from gori](/guide/mcp/#messages-from-gori) | Claude Code's inbox socket is a Unix socket, so it is never found on Windows. Operator messages reach Claude Code with the next tool result or through `operator_messages` instead. |
| Test coverage | The two legacy-schema migration spec files (`spec/store/*_autoincrement_migration_spec.cr`) are skipped, because on Windows they hang when run back to back in one process. Upgrading a project database from before those migrations is tested on POSIX only. |

## Not supported {#not-supported}

No release binary, no package and no CI. Some may [build from source](/getting-started/installation/#build-from-source), but nothing checks that they do.

| Platform | Note |
|----------|------|
| Windows arm64 | No gori build |
| 32-bit x86 and ARM Linux | No gori build |
| 32-bit Windows | No gori build |
| FreeBSD, OpenBSD | Untested from source |
| Other BSDs, Android, Solaris | Untested from source |
