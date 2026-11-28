# A complete nvim theme, not eighteen groups

## Why

The generated nvim file paints only Normal, Comment, String, Function, Type,
Pmenu, Visual, StatusLine and a few more. Everything else — LazyVim's
statusline, treesitter captures, diagnostics, diff, neo-tree, telescope/snacks
pickers — keeps the colours of whatever colorscheme LazyVim loaded, so the
editor looks half-themed.

## What changes

- The renderer paints the full set a modern LazyVim setup actually uses: base
  highlights, the treesitter `@` captures, diagnostics, diff/git signs,
  lualine, neo-tree, telescope and snacks picker groups.
- With a transparent background, panels and full-window surfaces (neo-tree,
  the snacks dashboard, trouble, lazy, noice mini) paint no background at all;
  floating windows and the statusline bars keep their surfaces for separation.
- Unknown plugin groups link to the painted base groups instead of a previous
  scheme's colours.
- The file is still one atomic apply, watcher/reload behaviour unchanged.

## Out of scope

- Plugin-specific features (icons, layout).
