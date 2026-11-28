# Launcher Specification

## Purpose

The panel, query surface and result list that every Palette feature appears in:
presentation, prefix routing, scoping, ranking, focus and provider failures.

## Requirements

### Requirement: Panel presentation

The launcher SHALL open from a global hotkey as an accessory app with no Dock
icon, at one fixed frame per display: 60% of each screen axis, capped by the
absolute limit when that is smaller. The frame SHALL NOT grow or shrink with
the result count, preview, provider bar or mode.

#### Scenario: Showing and hiding the panel

- **WHEN** the user presses the launcher hotkey while the panel is hidden
- **THEN** the panel appears at the fixed frame for the display under the pointer
- **AND** pressing the hotkey again, or Esc on an empty query, hides it

#### Scenario: Quit is a dismiss

- **WHEN** the panel is open and the user presses ⌘Q
- **THEN** the panel hides and the app keeps running

### Requirement: Window and panel size

`search_position` SHALL accept `top` or `center`; the legacy `bottom` value
SHALL be accepted and mapped to `center`. The embedded terminal SHALL open at
90% of the launcher width and 85% of its height, centred, while the scratchpad
SHALL keep the full launcher frame.

#### Scenario: Legacy position value

- **WHEN** `search_position = "bottom"` is in config
- **THEN** the panel opens centred and the old value is not rejected

#### Scenario: Terminal geometry

- **WHEN** `/term` opens on a 1440×900 launcher frame
- **THEN** the terminal panel is centred at 90% width and 85% height

### Requirement: Preview layout

`preview_layout` SHALL accept `auto`, `beside` or `below`. `auto` SHALL place
the preview beside the list when the fixed frame is wide enough and below it on
portrait frames. The preview SHALL take room from the list card and SHALL NOT
resize the window.

#### Scenario: Portrait auto layout

- **WHEN** `preview_layout = "auto"` on a portrait frame
- **THEN** the preview sits below the list

### Requirement: Prefix routing

A query that starts with the configured prefix character followed by a provider
trigger SHALL be routed to that provider. The token SHALL match the longest
declared trigger when triggers share a prefix, and SHALL only bind when the
token ends at whitespace or end of input.

#### Scenario: Longest trigger wins

- **WHEN** the user types `/bwn secret`
- **THEN** the query goes to the Bitwarden notes provider with text `secret`
- **AND** it is never read as `/bw` with text `n secret`

#### Scenario: Absolute path is not a prefix

- **WHEN** the user types `/Users/me/project`
- **THEN** no provider is bound and the text stays a plain query

### Requirement: Unfinished trigger token

A token that is a strict prefix of a declared trigger SHALL remain a plain
query, and Tab SHALL complete the shortest matching trigger with the prefix and
a trailing space. A token matching no trigger SHALL also stay plain.

#### Scenario: Tab completion

- **WHEN** the user presses Tab with `/cli` typed
- **THEN** the query becomes `/clip ` and the clipboard provider is active

#### Scenario: Unknown token

- **WHEN** the user types `/nope hello`
- **THEN** the whole string stays a plain query

### Requirement: Trigger hiding in the text field

Once a bound query has text, the text field SHALL hide the trigger token and
show the provider's pill instead. It SHALL keep showing the raw token while the
trigger is a prefix of a longer trigger with no separator yet, so the next
keystroke can complete the longer trigger.

#### Scenario: Hiding a settled trigger

- **WHEN** `/clip hello` is typed and the field renders
- **THEN** the field shows `hello` and the clipboard pill names the scope

#### Scenario: Keeping an ambiguous token visible

- **WHEN** `/bw` is bound but `bwn` is also a trigger and no space follows
- **THEN** the field still shows `/bw`

### Requirement: Plain-query scope

Apps SHALL always be searched for a plain query. Other providers SHALL join
only when listed in `[providers] global`; a prefix SHALL still reach any
enabled provider. Disabled providers SHALL be absent from plain search, the
rail and Tab cycling.

#### Scenario: Default allowlist

- **WHEN** `[providers] global` keeps its default and the user types `safari`
- **THEN** apps and the default plain providers are searched

#### Scenario: Prefix reaches a non-global provider

- **WHEN** `git` is absent from `[providers] global` and the user types `/git`
- **THEN** the git provider answers

### Requirement: Provider enablement and aliases

`[providers]` SHALL store rail order, disabled ids, extra trigger words and the
plain-query allowlist. A disabled provider SHALL remain configurable but SHALL
not answer, appear in the rail or take Tab focus. Duplicate aliases or triggers
SHALL be rejected when set, and the canonical trigger SHALL never change.

#### Scenario: Duplicate alias

- **WHEN** the user sets an alias already declared by another provider
- **THEN** Settings shows an inline error and does not write it

#### Scenario: Disabled provider

- **WHEN** `clip` is in `[providers] disabled`
- **THEN** `/clip` reports no provider and the rail omits the row

### Requirement: Empty and no-result states

An empty query SHALL show the app list, alphabetically or by use per `app_sort`,
with pinned apps and pinned web apps first. A query with no matches SHALL show
the web-search rows instead of a blank card; with web search off it SHALL show
a readable empty state.

#### Scenario: Opening with nothing typed

- **WHEN** the panel opens with an empty query
- **THEN** apps are listed in the configured order with pins on top
- **AND** unpinned web apps and running sessions are absent

#### Scenario: Nothing matches

- **WHEN** a query matches no app, file or provider row
- **THEN** the card shows one web-search row per enabled engine

### Requirement: Ranking

Result ranking SHALL be fzf-style: bands for exact, prefix, word-start,
substring and subsequence matches, with in-band bonuses for early and
consecutive fits. Matching SHALL fold case and diacritics. Equal scores SHALL
break by title, then stable id, so the order is deterministic.

#### Scenario: Non-contiguous match

- **WHEN** the user types `actmon`
- **THEN** Activity Monitor is found as a subsequence match

#### Scenario: Stable tie

- **WHEN** two rows score identically
- **THEN** they are ordered by title and then stable id on every run

### Requirement: Frecency and ranking memory

Frecency SHALL decay with a 30-day half-life. The learned prefix boost SHALL be
capped at +2.0 so it only breaks ties, never over a clearly better text match.
The query SHALL be stored only as a hash, the toggle SHALL live in Settings →
Search → Learning, and Forget SHALL clear it.

#### Scenario: Learning never beats a better match

- **WHEN** a learned prefix boost applies to one row
- **THEN** a clearly better text match still ranks above it

#### Scenario: Forget

- **WHEN** the user chooses Forget in Settings → Search
- **THEN** stored query hashes are cleared and boosting stops

### Requirement: Provider deadline and failures

Provider searches SHALL share a 300 ms deadline per keystroke. A provider that
misses it SHALL NOT hold the list. A failed provider, tool or launch SHALL
surface a visible row, status line or diagnostic rather than failing silently.

#### Scenario: Slow provider

- **WHEN** one provider is still working after 300 ms
- **THEN** the other results are shown and the slow provider's rows arrive later

#### Scenario: Missing tool

- **WHEN** a provider needs `fd`, `fzf`, `zellij`, `bw` or `gh` and it is absent
- **THEN** the panel offers an install row naming the tool
- **AND** nothing is installed automatically

### Requirement: Scopes

`[scopes.<name>]` SHALL define `roots`, `exclude`, `include`, `include_hidden`,
`max_depth` and `respect_gitignore`. A scope with no roots SHALL be skipped with
a warning; an invalid `max_depth` SHALL fall back to 12. A trailing slash in a
path query SHALL list a directory's direct children before descending.

#### Scenario: Default exclusions

- **WHEN** a scope keeps the default excludes and scans a repository
- **THEN** `node_modules`, `.git`, `.build` and `target` are not returned

#### Scenario: Scope without roots

- **WHEN** `[scopes.empty]` has no roots
- **THEN** it is skipped and a diagnostic names the scope

#### Scenario: Breadth-first browse

- **WHEN** the user types `/edit ~/dev/`
- **THEN** the direct children of `~/dev` are listed before deeper matches

### Requirement: Focus zones

The launcher SHALL have search, list, rail and group-strip focus zones. Tab
SHALL walk search → list → rail → strip and wrap; Shift-Tab SHALL reverse. Esc
SHALL leave the rail or strip, then clear the query, then dismiss. Tab SHALL
never change the provider.

#### Scenario: Esc unwind

- **WHEN** focus is on the rail and the user presses Esc
- **THEN** focus returns to search with the query and provider unchanged
- **AND** a second Esc clears the query and a third dismisses

#### Scenario: Tab does not switch provider

- **WHEN** focus is in the list and the user presses Tab
- **THEN** focus moves to the rail without changing the active provider

### Requirement: Launch failure visibility

When an open action fails, Palette SHALL keep the panel and its status line so
the error is readable, and SHALL only hide the panel after the launch call
succeeds. A missing path SHALL report the path instead of creating it, unless
the row explicitly opts into creation.

#### Scenario: Missing file

- **WHEN** a saved path no longer exists
- **THEN** the panel stays open with a message naming the path

#### Scenario: Successful launch

- **WHEN** an app opens successfully
- **THEN** the panel hides

### Requirement: Provider first response

A bound provider that shells out SHALL not make the user wait for a status probe
that could have been made in the background, and independent remote queries for
one provider SHALL run concurrently.

#### Scenario: First Bitwarden search after launch

- **WHEN** the user opens `/bw` shortly after launch
- **THEN** the vault status was already probed in the background and the row
  renders without a new CLI round trip

#### Scenario: GitHub list

- **WHEN** `/gh` fetches pull requests and issues for the first time
- **THEN** both queries are in flight at once rather than sequentially
