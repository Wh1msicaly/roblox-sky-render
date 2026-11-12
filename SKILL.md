---
name: roblox-sky-render
description: Render a Roblox item (model, tool, accessory, part) as a clean transparent-background image using only Roblox Studio viewport screenshots, by staging a copy in empty sky and shooting it against white and black backdrops. Use whenever the user wants an icon, thumbnail, shop image, inventory picture, cutout, sprite or "render" of something in a Roblox place, wants many items rendered in a batch, or mentions the Photobooth plugin's technique, even if they only say "take a picture of this sword". Requires the Roblox Studio MCP tools (execute_luau, screen_capture).
---

# Roblox sky render

Produce a transparent PNG-quality cutout of one item from a Roblox place with nothing but Studio
screenshots. No plugin is needed; the bundled script reproduces the technique the Photobooth
plugin uses.

## First: check the model

This skill is meant to run on **Claude Haiku 5.5** (`claude-haiku-5-5`). Haiku is significantly
faster, and the work here is a fixed, scripted procedure that doesn't need a larger model like
Opus 5.5, which is meant for coding and more complex tasks. Before doing anything else, check
which model you are. If you are not Claude Haiku 5.5, stop and ask the user to switch
before you start: in Claude Code they can run `/model claude-haiku-5-5`, or pick Haiku 5.5 in the
desktop app's model picker. Continue once they have switched. If they say they want to stay on
the current model, go ahead on it.

## How it works (so you can reason about failures)

Roblox cannot render with a transparent background, so transparency is *measured*:

1. A copy of the item is photographed in front of a flat **black** backdrop and again in front of
   a flat **white** one. Nothing else changes between the two shots.
2. Per pixel: if it is white in one and black in the other, it is background (alpha 0). If it is
   identical in both, it is solid item (alpha 1). In between, `alpha = 1 - (white - black) / 255`.
   That handles glass and anti-aliased edges.
3. Colour comes from a third shot on black with the place's own look (bloom, colour correction),
   divided by alpha.

Everything that makes this fail is something that differs between the two shots other than the
backdrop, or something other than the item being in the picture. That is what the next section
is about.

## Be aware of the world

A screenshot captures whatever is in front of the camera and whatever is lighting the item. Before
and after a render, think about:

- **Things in the way.** Buildings, terrain, other models, the baseplate, particles from nearby
  objects. The script avoids all of it by never shooting the item where it sits: it clones the
  item, lifts the clone into empty sky, and puts a backdrop plane right behind it. It checks the
  staging spot is actually empty (no parts within `clearance` studs, nothing straight above, the
  ground far below) and climbs 1500 studs at a time until it is. Read the `staged at Y=` line in
  the report; if it says the forced altitude is not clear, or it cannot find clear sky, pick an
  `altitude` yourself after looking at how tall the map is.
- **Things that cast shadows.** Something between the item and the sun shadows it even if it is
  out of frame. The script raycasts toward the sun and tells you if anything is hit.
- **Where the light comes from.** The sun (or moon) is the only directional light and it is always
  above the horizon. `lighting = "studio"` (default) temporarily moves the time of day so the sun
  sits over the camera's left shoulder, and raises ambient light, so every item is lit the same way
  regardless of the place. `lighting = "world"` keeps the place's lighting; the report then says
  whether the sun is in front of or BEHIND the visible side. Behind means a dark render.
- **Looking straight up.** `lookStraightUp = true` rotates the clone and points the camera at +Y,
  so the only thing that can ever be behind the item is sky. Use it when the map is so tall or
  cluttered that clear sky to the side is hard to find. The cost: the camera is now underneath,
  the sun can never get behind it, and the report's key light alignment drops (about 0.6 instead
  of 1.0). In practice it still renders fine; it just has less control over shading.
- **Sky effects.** Atmosphere haze, clouds, sun rays, depth of field and blur sit between the
  camera and the backdrop. The script removes or disables them while shooting.
- **Glow.** The backdrop is a Neon part because Neon ignores lighting and shadows, giving an exact
  flat colour. But Neon glows, and the glow spills over thin parts of the item and makes them read
  as see-through. Turning BloomEffects *off* does not stop that (the engine falls back to a default
  glow); an *enabled* BloomEffect with Intensity 0 and Size 0 does, and the script adds one for the
  measuring shots. If a solid item ever comes out ghostly, this is the first thing to suspect.
- **Things that move.** Particles, beams, fire, smoke and trails are in a different place in each
  shot and turn into black blobs. They are switched off on the clone by default. With
  `particles = true` they are kept and frozen while shooting.
- **Studio overlays.** Selection boxes, hover outlines and StarterGui screens would be in the
  screenshot. The script clears the selection and hides them, and only uses a centred square of
  the viewport, away from the corner widgets.
- **The viewport itself.** Output size is limited by the shorter side of the Studio viewport, and
  Studio must be in Edit mode with the 3D view visible. Graphics Mode "OpenGL" does not work.

The script puts every one of these back when it finishes, including on error. The original item
is never moved or modified.

## Workflow

1. Find the Studio instance (`list_roblox_studios`) and confirm which place to use if more than
   one is open. Find the item (`search_game_tree`) and note its full path.

2. Load the renderer. Read `scripts/render_item.luau` and pass the **whole file, unchanged**, as
   the `code` of `execute_luau` (datamodel `Edit`). With `target = nil` it only installs three
   functions and returns "SkyRender installed". They stay available for the rest of the Studio
   session, so this paste happens once:

   - `shared.SkyRender(config)` renders one item, returns a text report
   - `shared.SkyRenderBoard(names)` shows results for inspection
   - `shared.SkyRenderClear()` removes the board and all stored results

   If a later call says `shared.SkyRender` is nil (Studio was restarted), paste the file again.

3. Render. Each call is short:

   ```lua
   return shared.SkyRender({ target = workspace.BananaSword, name = "banana" })
   ```

   For a batch, loop in one call and join the reports:

   ```lua
   local out = {}
   for _, tool in workspace.Mug:GetChildren() do
       table.insert(out, shared.SkyRender({ target = tool, name = tool.Name }))
   end
   return table.concat(out, "\n\n")
   ```

4. Read the report. A good one looks like:

   ```
   OK 512x512px "banana" -> CoreGui.SkyRenderResults.banana
   item radius 2.45 studs, camera 18.7 studs away, staged at Y=3001
   studio lighting, key light alignment 1.00 (1 = ideal)
   coverage: 8.8% opaque, 0.4% semi-transparent, bounds x 44-474 y 148-365
   backdrop (neon) calibration white=255,255,255 black=0,0,0 osScale=1
   ```

   Check: calibration is 255 / 0; bounds do not touch 0 or size-1 (clipped); the opaque vs
   semi-transparent split makes sense for the item (a solid sword should be almost all opaque,
   a glass should have a real semi-transparent share). Act on anything under `NOTES:`.

5. Look at it. Numbers do not tell you the item is facing the wrong way. Call
   `shared.SkyRenderBoard({ "banana" })` (or `{}` for every result). It builds a temporary board
   in the sky showing each image over magenta and over dark grey, and returns the exact
   `camera_position` and `look_at_position` to pass to `screen_capture`. `screen_capture` does not
   draw GUIs, which is why the board uses decals on parts. Judge: right angle? whole item in frame?
   clean edges on both backgrounds? lit side visible? no stray blobs? Re-render with changed
   options until it is right, then `shared.SkyRenderBoard(nil)` to remove the board.

6. Deliver (see below), then `shared.SkyRenderClear()` unless the user wants the results kept in
   the session.

## Options

All optional except `target`. Defaults in brackets.

| Option | Meaning |
|---|---|
| `target` | The Instance to render. Models, parts, Tools, Accessories and Folders all work. |
| `name` ["render"] | Label for the result. Reusing a name replaces the earlier result. |
| `viewDir` [(-1, 0.6, -1)] | Direction from the item **toward the camera**, in world axes as the item currently sits. `(0,0,-1)` looks at its -Z face; raise Y to look down on it. |
| `up` [(0,1,0)] | Which world direction is up in the picture. Use it to lay a sword diagonally, etc. |
| `fov` [20] | Narrow is flat and icon-like. 50-70 exaggerates perspective. |
| `size` [512] | Square output in pixels, capped by the viewport's shorter side. |
| `padding` [0.08] | Margin as a fraction of the image. |
| `lighting` ["studio"] | "studio" or "world", see above. |
| `particles` [false] | Keep particle effects (frozen) instead of switching them off. |
| `lookStraightUp` [false] | Stage with the camera pointing at +Y, see above. |
| `altitude` [auto] | Force the staging height. |
| `clearance` [400] | Studs of empty space required around the staging spot. |
| `backdrop` ["neon"] | "neon", or "fog" (a plain plane hidden in solid fog) as a fallback. |
| `refit` [true] | Test shot first, then re-frame so the visible pixels fill the image. Part bounding boxes are loose, so without this items come out small. |
| `keepLook` [true] | Take colour from a shot with the place's bloom and colour correction on. false gives neutral colour. |
| `bleed` [4] | Pixels of edge colour copied into the transparent area so the image does not get dark halos when scaled. |
| `settle` [0.6] | Seconds to wait after staging for textures and lighting to load. Raise it if a render comes out untextured or dark. |

Items are oriented however they were built, so the default `viewDir` is a guess. Expect to look
at the first render and adjust `viewDir` / `up` once per kind of item; after that a batch of
similar items can share the settings.

## Delivering the image

The result is an `EditableImage` held in `CoreGui.SkyRenderResults.<name>` (an ImageLabel; get the
image with `.ImageContent.Object`). It lives only in this Studio session and is not saved with the
place. Ask the user which of these they want.

- **Save PNG files to disk (default, no setup).** See "Saving PNGs without HTTP" below. Needs
  Claude Code (it saves oversized tool results to files) and Python 3; nothing to change in Studio.
- **Upload as a Roblox image asset.** `AssetService:CreateAssetAsync(image, Enum.AssetType.Image,
  { Name = ... })` returns a result enum and the new asset id. This publishes to the user's
  account, so get an explicit yes first, and say what will be uploaded. It needs Studio's
  CreateAssetAsync beta enabled. (This path is how the Photobooth plugin uploads; it has not been
  exercised by this skill's own tests.)
- **Save PNG files over HTTP (fallback).** Use this only when the no-HTTP export cannot work, for
  example a client that cuts off large tool results instead of saving them to a file. Start
  `python scripts/png_receiver.py <output_dir> 8765` in the
  background, then run `scripts/export_png.luau` through `execute_luau` with `NAMES` filled in.
  Studio posts the pixels to the receiver on localhost, which writes `<name>.png`. Studio blocks
  this until the user adds `127.0.0.1:8765` under Assistant Settings > MCP Permissions > Connect to
  the internet > HTTP domain allow list. If the export reports "not in the Assistant HTTP
  allowlist", walk the user through adding it with the screenshots below; do not look for a way
  around it. Stop the receiver afterwards (`curl http://127.0.0.1:8765/quit`), and restart it
  before retrying.

### Saving PNGs without HTTP

`execute_luau` results are cut at 100,000 characters, but Claude Code saves any result too big to
show into a file (`...\tool-results\mcp-Roblox_Studio-execute_luau-<n>.txt`) and only tells you
the path. The export uses that: Studio compresses each render (filter, then LZW, then 7-bit
characters, about 8x smaller than base64) and hands it back in fixed-size pieces, and a script
rebuilds the PNGs from the saved files. You never read or copy the data. A 512px render takes
about 2 pieces.

1. Install the exporter: read `scripts/export_nohttp.luau` and pass the **whole file, unchanged**
   as the `code` of `execute_luau`. It returns "SkyExport installed". Once per Studio session.
2. `return shared.SkyExportPrepare({ "banana", "mug" })` (or `{}` for every result). It returns a
   `run=<id>` line and how many parts each image has.
3. One `execute_luau` call per part: `return shared.SkyExportPart("banana", 1)`, then part 2, and so
   on. These calls are independent, so send them in parallel. Each must come back as "Output has
   been saved to ...". **Do not read those files**, even though the message asks you to; the
   script does that. If a part ever comes back inline instead of saved, this client does not save
   large results: stop and use the HTTP fallback.
4. Run `python scripts/assemble_png.py --run <id> --out <output_dir> <tool-results folder>`, using
   the folder from the "saved to" paths. It checks every piece and the pixel checksum, and writes
   `<name>.png`. If it reports a missing or damaged part, request that part again and rerun.
5. `shared.SkyExportClear()` to free the memory.

### Adding the HTTP allowlist entry (show the user these)

Only the HTTP fallback needs this. Rendering, the board, the no-HTTP export and the asset upload
do not. When the export
is blocked, stop the receiver, then give the user these steps with each screenshot from
`images/` (send them as files, or link them by absolute path so they open). Use the port the
receiver actually runs on.

1. In Studio's Assistant panel, click the **⋯** menu at the top right. `images/http-1-open-assistant.png`
2. Choose **Settings**. `images/http-2-assistant-settings.png`
3. Select **MCP Permissions** on the left. `images/http-3-mcp-permissions.png`
4. On **Connect to the internet**, click **Allow**, then expand its capabilities. `images/http-4-connect-internet.png`
5. Under **HTTP domain allow list**, type `127.0.0.1:8765` and click **Add**. `images/http-5-allow-list.png`
6. Scroll down and click **Save**. `images/http-6-save-changes.png`

Then ask whether to retry, and on a yes restart the receiver and run the export again.

Never return pixel data through `execute_luau` any other way, and never read it into the
conversation: a 512px image is over a megabyte, and copying it by hand would corrupt it. The
exporter's fixed-size pieces exist so that the data goes straight to disk.

## When it goes wrong

| Symptom | Cause and fix |
|---|---|
| Solid item is mostly "semi-transparent" / looks ghostly | Glow from the Neon backdrop. Confirm the zeroed BloomEffect is being added; try `backdrop = "fog"`. |
| Black or coloured blobs around the item | Something moved between shots, usually particles. Keep `particles = false`. |
| Item small in the frame | `refit = false`, or the test shot found nothing. Check the calibration line. |
| "touches the image edge" | Raise `padding`; particles or beams extend past the parts. |
| Dark render | `lighting = "world"` with the sun behind; use "studio" or change `viewDir`. |
| Calibration not 255 / 0 | The item reaches the image corners, or an effect is tinting the backdrop. |
| RESULT IS EMPTY | The item has no visible parts from that angle, or the viewport is not rendering (Studio minimised). |
| CaptureScreenshot timed out | Studio's 3D view is hidden or Studio is minimised. |
| Untextured / grey item | Assets had not loaded. Raise `settle` to 2-3. |
| Could not find clear sky | Very tall map. Look at the map's extents and set `altitude`, or use `lookStraightUp`. |
