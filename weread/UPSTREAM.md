# WeRead source provenance

Vendored from [finlater/weread.koplugin](https://github.com/finlater/weread.koplugin),
version 1.7.0, commit `cf39ef68a1b02d11a37bddf70fc9a6b630f21f18`,
retrieved on 2026-11-17. Copyright 2026 finlater and contributors.
Licensed under GNU AGPL version 3; see `../LICENSE.weread` and
`../NOTICE.weread`.

WeUI uses its own entry point, paper interface and updater. Host adaptations
live in `../weui_weread_features.lua`, `../lib/weread_client.lua` and
`../lib/weread_downloader.lua`. The upstream service modules retain their
namespaces so their regression specifications can be run independently.

Test adaptations omit the standalone metadata assertion and the presence of
an upstream promotional QR image. WeUI retains its own metadata and does not
ship that promotional asset. `thought_popup/face_factory.lua` also resolves
the bundled emoji font relative to the integrated plugin's source path.
`background_worker.lua` adds an explicit teardown hook for WeUI's plugin
disable path.
The host also persists a catalog obtained from an automatic EPUB descriptor or
the local catalog cache into the shared annotation store, allowing later local
book bindings to reuse downloaded sources offline.
