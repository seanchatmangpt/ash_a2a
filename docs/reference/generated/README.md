<!-- GENERATED — regen, never hand-edit. -->

# Generated reference skeletons (doc-hdit scaffold)

GENERATED — do not hand-edit the reference tables.

- Source of truth: ash_a2a code surface, extracted by
  `ggen-marketplace/scripts/gen_doc_surface.py code /Users/sac/ash_a2a`.
- Renderer: `doc-hdit scaffold` from `ggen-marketplace/packs/rust-doc-hdit-pack`
  (templates in that pack's `templates/`).
- Regen command:

  ```sh
  python3 /Users/sac/ggen-marketplace/scripts/gen_doc_surface.py code /Users/sac/ash_a2a \
    > /tmp/hdit/ash_a2a.code.v3.json
  /Users/sac/ggen-marketplace/packs/rust-doc-hdit-pack/target/release/doc-hdit scaffold \
    --code /tmp/hdit/ash_a2a.code.v3.json \
    --templates /Users/sac/ggen-marketplace/packs/rust-doc-hdit-pack/templates \
    --out /Users/sac/ash_a2a/docs/reference/generated
  ```

- The reference tables under `reference.md` are rigid (see the
  AGENT-FORBIDDEN banner in the file): every row is rendered from the
  extracted code surface. Prose lives only in the fenced slot.
- Known extractor limits (disclosed, not hand-filled):
  - ash_a2a is a multi-app repo (root mix.exs plus `actuator/`, `authority_service/`,
    `examples/a2a_demo/`, `sa2a_crypto/`, `swarm/`); each app's modules are scanned, so
    module-name collisions render as duplicate rows in one table.
  - The scan also walks `tmp/` mix.exs fixtures, so transient sandbox apps can appear in the
    version map — regen after cleaning `tmp/` for a stable surface.
  - v1 is a regex + do/end-depth scanner, not an AST parser; disclosed in
    `ggen-marketplace/scripts/doc_surface_conventions.md`.
