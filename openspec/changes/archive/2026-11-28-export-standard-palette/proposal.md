# Publish the palette in a standard format

## Why

Every supported app currently costs a bespoke adapter. That is necessary only
for apps that must be recoloured *live*; for everything else the palette should
be consumable as a file. Publishing one canonical scheme in a format other tools
already read makes each future app cost zero.

## What changes

- On every apply, write the active palette in two standard shapes next to the
  existing generated files:
  - `palette.yaml` — base16 scheme (`scheme`, `author`, `base00`…`base0F`);
  - `palette.terminal-sexy.json` — terminal.sexy's 16-colour JSON.
- Keep the per-app generated files: they carry the live-reload behaviour.

## Out of scope

- Installing those files into other apps automatically.
- Changing the existing targets or their managed blocks.
