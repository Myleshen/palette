# Security Specification

## Purpose

Trust boundaries: command execution, outbound URL policy, child-process
environment, file permissions, secret handling, and the update path. See
[ADR 0009](../../decisions/0009-strict-ssrf-url-policy.md) and
[ADR 0008](../../decisions/0008-adhoc-signing.md).

## Requirements

### Requirement: Structured command execution

`/cmd` SHALL read `commands.toml`, where each `[[command]]` declares title,
keywords, executable, arguments, optional working directory, terminal or GUI
mode, and whether to confirm. `config.toml` SHALL NOT contain inline shell
strings, and a command marked `confirm = true` SHALL ask before running.

#### Scenario: Confirmed command

- **WHEN** a command has `confirm = true` and the user activates it
- **THEN** a confirmation prompt appears and declining runs nothing

#### Scenario: Arguments with spaces

- **WHEN** an argument contains a space or shell metacharacter
- **THEN** it is passed as one argument and is not interpreted by a shell

### Requirement: Custom binding execution

A `[[binding]]` with `action = "command"` SHALL run its value in `/bin/zsh -lc`
with no terminal window and SHALL write a failure to the app log. An invalid,
repeated or built-in-conflicting key SHALL show an inline Settings error, be
skipped at runtime with a log warning, and SHALL NOT take the app down.

#### Scenario: Invalid binding

- **WHEN** a binding key cannot be parsed
- **THEN** Settings reports it and the remaining bindings still register

#### Scenario: Command failure

- **WHEN** a custom command exits non-zero
- **THEN** the failure is logged and no panel is left open

### Requirement: Outbound URL policy

A URL contacted automatically SHALL be https only. Its host SHALL NOT be a
literal or resolved loopback, unspecified, private, link-local, unique-local or
multicast address, and legacy numeric encodings such as `127.1`, `2130706433`
or `0x7f000001` SHALL be rejected. Both literal and DNS-resolved addresses
SHALL be checked.

#### Scenario: Private IPv4

- **WHEN** a page links `https://192.168.0.10/logo.png`
- **THEN** the request is refused

#### Scenario: Hostname resolving private

- **WHEN** `internal.example` resolves to `10.0.0.5`
- **THEN** the request is refused

#### Scenario: Plain HTTP

- **WHEN** a fetched URL uses `http://`
- **THEN** it is refused

### Requirement: Redirect guard

A redirect SHALL be cancelled when its target fails the URL policy, before the
request is followed. No private-host redirect SHALL be fetched and rejected
after the fact.

#### Scenario: Public to private redirect

- **WHEN** a public page redirects to `https://127.0.0.1/admin`
- **THEN** the redirect is cancelled

### Requirement: Child environment sanitising

Palette SHALL remove API key environment variables and `BW_SESSION`/
`BW_PASSWORD` from every child environment. A child SHALL receive a secret only
when a caller passes it explicitly, as the Bitwarden CLI does with
`BW_SESSION`.

#### Scenario: Provider script

- **WHEN** a command provider starts
- **THEN** it does not inherit `OPENCODE_GO_API_KEY`, `NVIDIA_API_KEY`, `BW_SESSION` or `BW_PASSWORD`

#### Scenario: Bitwarden

- **WHEN** Palette runs `bw` with an explicit session
- **THEN** that one process receives `BW_SESSION`

### Requirement: Provider process limits

A command provider SHALL run with a timeout of at least 100 ms (default 2,000
ms) and a filesystem walk SHALL respect `max_entries`. A timed-out child SHALL
be terminated rather than left running.

#### Scenario: Hung provider

- **WHEN** a provider ignores its deadline
- **THEN** the process is killed and the provider reports a timeout

### Requirement: File permissions

State, cache and config secrets SHALL be user-only: clipboard images and their
directory, the database, logs, pending clipboard clears, key files and exported
backups SHALL be `0600`; image and vault directories SHALL be `0700`. A
permission failure SHALL be logged, not silently ignored.

#### Scenario: New database

- **WHEN** Palette creates its SQLite database
- **THEN** the file mode is `0600`

#### Scenario: Clipboard image

- **WHEN** a clipboard PNG is written
- **THEN** the file mode is `0600` under a `0700` directory

### Requirement: Secret storage

API keys SHALL never appear in `config.toml`, logs or history, and a saved key
SHALL never be displayed again. Bitwarden's vault cache SHALL be sealed with
AES-GCM under `~/Library/Caches/Palette/Bitwarden` for thirty days with a
`0600` per-user key, scoped to `BITWARDENCLI_APPDATA_DIR`. The master password
SHALL never be stored.

#### Scenario: Restart within the cache window

- **WHEN** Palette restarts within thirty days
- **THEN** it reads the sealed vault cache without asking for the master password

#### Scenario: Different CLI profile

- **WHEN** `BITWARDENCLI_APPDATA_DIR` changes
- **THEN** the cache from the other profile is not used

### Requirement: Obscured secret storage is documented

The Ask key file SHALL be described as obfuscation, not confidentiality: anyone
who can read both the sealed values and the key file can decrypt them. The
documentation SHALL NOT claim Keychain-grade protection.

#### Scenario: Reading the docs

- **WHEN** a user reads the key storage section
- **THEN** it states the limitation and where both files live

### Requirement: Update path

Palette SHALL check GitHub for a newer release at most once a day, cache the
answer, back off after failures, and SHALL never install anything itself. The
offered action SHALL run `brew update && brew upgrade --cask palette` in the
embedded terminal, and `[updates] automatic = false` SHALL disable the check.

#### Scenario: Update available

- **WHEN** a newer release is found
- **THEN** the menu offers the update and choosing it opens the terminal running the brew command

#### Scenario: Network failure

- **WHEN** the daily check fails
- **THEN** the last known answer stays and retries back off

#### Scenario: Updates disabled

- **WHEN** `[updates] automatic = false`
- **THEN** no automatic check runs

### Requirement: Release integrity

A release SHALL be published as a draft with GitHub build provenance and a
`SHA256SUMS` asset, and a post-release job SHALL download the assets and verify
the checksum and signature. A tag not on `main` SHALL NOT publish.

#### Scenario: Verifying a download

- **WHEN** a user downloads the zip and `SHA256SUMS`
- **THEN** `gh attestation verify` and `shasum -a 256 -c` both pass

### Requirement: Ad-hoc signing model

Palette SHALL be ad-hoc signed without a Developer ID, notarisation or hardened
runtime, so TCC grants are keyed only to the bundle identifier and may be
re-requested after a rebuild. Documentation SHALL warn that any app with the
same identifier can inherit a grant and that only self-built or official builds
should be run.

#### Scenario: Rebuild

- **WHEN** the app is rebuilt and relaunched
- **THEN** macOS may ask for Accessibility or Screen Recording again

### Requirement: Failed open is visible

An open action SHALL hide the panel only after the launch succeeds. A missing
browser SHALL fall back to the default with a message, a failed web-app window
SHALL open as a tab, and a total failure SHALL keep the panel and name the
reason.

#### Scenario: Uninstalled browser

- **WHEN** a bookmark names a browser that is not installed
- **THEN** the link opens in the default browser and the panel says so

#### Scenario: Nothing opens

- **WHEN** the URL cannot be opened at all
- **THEN** the panel stays open with the failure reason
