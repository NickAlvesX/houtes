# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project state

This is a brand-new Godot project named `puzzle-path`. As of now it contains only the default
project scaffold (`project.godot`, `icon.svg`) — there are no scenes, scripts, or game logic yet.
There is no README. Treat any described "architecture" in this file as provisional: update this
file as real structure (scenes, scripts, autoloads) gets added, since there isn't yet a codebase
to infer conventions from.

## Engine / config

- Godot version: **4.8**, rendering method: **Forward Plus**.
- Physics: Jolt Physics is configured for 3D (`physics/3d/physics_engine="Jolt Physics"` in
  `project.godot`), so this is expected to be (or become) a 3D project, not 2D.
- Display stretch mode is `canvas_items` with `expand` aspect — UI/viewport scaling assumes a
  resizable window rather than a fixed resolution.
- Windows rendering driver is pinned to `d3d12` (`rendering_device/driver.windows="d3d12"`).

## Commands

There is no CLI build/test/lint tooling in this repo yet (no `export_presets.cfg`, no GUT or other
test addon, no CI config). Development happens through the Godot editor:

- Open the project: `godot4 --path .` (or `godot --path .` depending on how Godot is installed/aliased).
- Run the project from the command line: `godot4 --path . --headless` is NOT appropriate for this
  3D/rendered project; use a normal (non-headless) run: `godot4 --path .`.
- There is no main scene set yet (`run/main_scene` is absent from `project.godot`), so running the
  project from the editor will prompt to select a scene until one is configured.

If test/build tooling (e.g. GUT for unit tests, export presets, a justfile/Makefile) is added
later, update this section with the concrete commands.

## Working conventions

- `.gitattributes` normalizes all text files to LF line endings — don't fight this when creating
  new files.
- `.godot/` (the editor's generated cache/import directory) is gitignored; never hand-edit or rely
  on files under it, and don't treat its contents as source of truth for project config (that's
  `project.godot`).
