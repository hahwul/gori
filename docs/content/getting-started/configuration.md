+++
title = "Configuration"
description = "Where gori stores data, how to configure the network, and the root CA."
weight = 40
+++

gori keeps global preferences in a JSON settings file and stores each project as its own SQLite database. This page covers the essentials you need on day one: where things live, how the proxy binds, and how clients trust gori's CA. For the full, key-by-key breakdown, see the [Configuration Reference](/reference/config/).

## The gori Home Directory

Everything gori writes lives under a single tree, `GORI_HOME` — `$GORI_HOME` when that variable is set and non-empty, otherwise `~/.gori`. It holds `settings.json` (global preferences), your project databases under `projects/`, the root CA in `ca/`, plus `themes/` and `wordlists/`. See [Storage Layout](/reference/config/#storage-layout) for the full tree.

Point gori at an isolated home for a session:

```bash
GORI_HOME=/tmp/gori-scratch gori
```

## Global Settings

Global preferences are stored in `settings.json`. Print its path, or open it in `$EDITOR`:

```bash
gori settings          # print the settings.json path
gori settings --edit   # open it in your editor
```

You rarely need to edit the file by hand. Everything in it is editable in-app from one surface, the **Preferences** modal, grouped into four sub-tabs (General, Appearance, Editor & Keys, Network & Tabs):

| Open it with | Lands on |
|--------------|----------|
| `Ctrl-,` from anywhere | The group strip, so you pick a group first |
| The `⚙` chip in the top bar | Same as `Ctrl-,` |
| `Ctrl-P` → any **Settings: …** entry | That section's fields directly |

`Ctrl-,` also works in the project picker, before any project is open, so you can set your theme on first launch. Saved changes apply live, no restart. See the [Settings guide](/guide/settings/) for every section and field, and the [Configuration Reference](/reference/config/) for the underlying keys.

## Network

By default the proxy listens on `127.0.0.1:8070` and connects directly to targets. You can change that in three places, highest priority first:

1. **Per-project** — pin a bind address, port, and upstream for one project from the **Project** tab; these win for that project only.
2. **CLI flags** — `--listen` / `--port` override the global default for the current process, without writing to disk.
3. **`settings.json` `network`** — the shared default, edited by the first-run wizard and Preferences → **Network**.

When nothing is set, the factory default is `127.0.0.1:8070`, direct. See [network](/reference/config/#network) for every key and [Per-Project Overrides](/reference/config/#per-project-overrides) for the exact precedence.

## The Root CA

To intercept HTTPS, clients must trust gori's root certificate, kept in `~/.gori/ca` as `root.crt.pem` and `root.key.pem`.

```bash
gori ca                       # print the certificate path
gori ca --pem                 # print the PEM to stdout
gori ca --ca-dir /path        # use a custom CA directory
gori ca regenerate --yes      # replace the root CA (scripts/CI; voids prior trust)
```

You can also rotate the CA from the TUI command palette (**Regenerate CA certificate**), or interactively with `gori ca regenerate` (type `regenerate` to confirm). Both paths are confirm-gated because rotation invalidates all previously issued trust; any already-running gori keeps the old CA until restarted.

### Bring your own CA

To reuse one CA across a team or machines, generate a root externally and import it (cert **and** key: gori signs leaf certificates with the key; clients trust only the cert):

```bash
openssl ecparam -genkey -name prime256v1 -out root.key.pem
openssl req -x509 -new -key root.key.pem -days 3650 -subj "/CN=my ca" -out root.crt.pem
gori ca import --cert root.crt.pem --key root.key.pem --yes
```

The same action is available from the palette (**Import CA certificate**). gori checks the key matches the cert and that it is a CA before adopting it. Distribute only `root.crt.pem` to trust; keep `root.key.pem` secret. See [`gori ca import`](/reference/cli/#gori-ca-import).

The palette's **Open browser** action launches an installed browser with an isolated profile that already trusts the CA and routes through the proxy (see the [Quick Start](/getting-started/quick-start/)).

## Full Reference

See the [Configuration Reference](/reference/config/) for every settings key and the [CLI Reference](/reference/cli/) for all command-line flags.
