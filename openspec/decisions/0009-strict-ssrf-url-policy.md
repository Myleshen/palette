# 0009. Strict SSRF policy for every automatic fetch and redirect

- Status: accepted
- Date: 2026-11-27

## Context

Ask fetches pages from search results, direct links in a message, markdown
images and favicons. Those URLs come from the model or a third party. A naive
URLSession call would let a hostile page redirect to `http://127.0.0.1:…` or to
a router at `192.168.x.x`, turning the app into a local-network probe. The app
has no server, but it runs with the user's access.

## Options considered

- **Block literal private hosts only.** Misses DNS names that resolve private
  and redirects that switch host after the first check.
- **Ask the user before each fetch.** Safe but unusable for a streaming answer
  with several sources.
- **A shared https-only policy that checks literals, resolved addresses and
  every redirect, implemented once.**

## Decision

`SafeURL` is the single check. A URL must be https; its host must not be a
literal or resolved loopback, unspecified, private, link-local, unique-local or
multicast address; legacy numeric encodings (`127.1`, `2130706433`, `0x7f000001`,
octal) are rejected as hosts. Hosts are canonicalised (case, trailing dot,
brackets) and resolved before use. `RedirectGuard` cancels any redirect whose
target fails the same check, so a private target is never followed and then
rejected. The guard is used by page fetches, markdown images, favicons and web
app icons.

## Consequences

- No automatic request can reach the local machine or a private network.
- A legitimate intranet page cannot be summarised by Ask; the error is visible.
- Every new network surface must use `SafeURL`; a plain `URLSession` call is a
  bug.
- DNS rebinding is narrowed but not eliminated between resolution and connect;
  the redirect guard and https-only rule are the main controls.

## Links

- [specs/security](../specs/security/spec.md)
- [specs/ask](../specs/ask/spec.md)
