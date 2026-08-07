# Embedded Z-Library source

This directory vendors the Z-Library implementation from
`ZlibraryKO/zlibrary.koplugin` tag
`v1.0.43-302bed328645593fe1f67d626b7b577b9ff39999`.

Integration changes are intentionally limited to `embedded_plugin.lua`:

- the standalone plugin entry point is loaded as a child module of WeUI;
- the plugin root is resolved one directory above `zlibrary/`;
- standalone menu registration is removed in favour of WeUI's unified menu;
- the standalone Z-Library OTA entry is removed because WeUI updates the
  embedded source together with the rest of the plugin.

Trailing whitespace in vendored Lua and Markdown files is normalized to keep
the host repository's patch checks clean; this does not change behavior.

The vendored source is licensed under AGPL-3.0. See `../LICENSE.zlibrary`.
