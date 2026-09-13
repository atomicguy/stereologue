# Stereologue — Fall 2026 Revision Plan

Branch: `fall-2026-revision`. Baseline commit: `62d7610` (SCUNet removed,
stereo-aware repair consolidated).

Two user-visible problems drive this plan: grid scrolling still hitches, and
image enhancement hangs or crawls on visionOS. The phases below are ordered so
each one ships a usable improvement on its own. Effort estimates assume one
developer, working days.

---

## Phase 1 — Stop the visionOS hang (1–2 days) — ✅ implemented

Status: shipped on `fall-2026-revision` (see `git log`). Crop-override cache
invalidation is done by keying on crop geometry rather than by calling
`evict`, which keeps `UserDataService` decoupled from the photo service.
Remaining: measure the done-when numbers on hardware.

Follow-up: the "deep" pass (`StereoPairProcessor`) was subsequently removed
outright rather than kept opt-in. Its detector missed most real scratches at
scan resolution and general-purpose optical flow was unreliable across stereo
disparity, so the visible effect was negligible for its cost. The
`deep`/debug-mask plumbing is gone from the renderer, service, and both
viewers; the code is recoverable from git history and its sibling-fill idea
seeds Phase 3.

Goal: picking a restoration style in the spatial viewer returns in seconds and
never blocks navigation. No new algorithms; this is defaults, scheduling, and
cancellation.

1. **Make the deep pass opt-in everywhere.**
   `SpatialPhotoService.spatialHEICData` and `prefetch` default `deep` to
   `false`. Prefetch never runs deep. The visionOS viewer gets the same
   "Deep Restore" toggle the wiggle view has; it applies only to the current
   card on an explicit tap.
2. **Move heavy work off the service actor.**
   Everything in `preparedStereoPair` after the download — crop, restore,
   `matchPair`, rectify, `StereoPairProcessor.process`, HEIC encode — runs in a
   `nonisolated` async renderer (`Task.detached` or a nonisolated async
   function), not inside the actor's executor. The actor keeps only the data
   cache, in-flight map, and coalescing. A cache hit for card B must never wait
   behind a deep render of card A.
3. **Cancellation.**
   The renderer checks `Task.isCancelled` between stages. `spatialHEICData`
   propagates cancellation to the in-flight task when the last waiter goes away
   (reference count per variant). `SpatialPhotoView`'s `.task(id:)` cancelling
   then actually stops work.
4. **Surface errors and progress.**
   `applyStyle` in `SpatialPhotoView` shows an alert on failure instead of
   logging. The restoring spinner becomes a cancellable state.
5. **Honor crop overrides on visionOS.**
   `SpatialPhotoView` builds its snapshot with
   `card.spatialPhotoData(cropOverride:)`. The cache variant key includes a
   hash of the effective detections so an edited crop never serves stale data.
   Call `evict(cardUUID:)` from `UserDataService.saveCropOverride` /
   `deleteCropOverride`.

Done when: on Vision Pro, Original→Enhance on a 2560 px card completes in
under ~3 s without deep; swiping mid-render shows the next card promptly; a
crop edit is reflected in the spatial viewer on next open.

---

## Phase 2 — Smooth scrolling (2–3 days) — ✅ implemented

Status: shipped on `fall-2026-revision`. Every card grid now scrolls over
`CardRow` values fetched in offset pages of 80 by `CatalogQueryService`; a
`#Index` on `title` was added so title-ordered pages deep into the catalog
are cheap (verified against the bundled store in `StereologueTests`, which
also exercises the lightweight migration users' installed stores will run).
Remaining: item 6, the Instruments numbers on iPad Pro and Vision Pro.

Goal: the Library grid (41K cards) and every other card grid scroll at frame
rate on iPad and Vision Pro, with no main-thread SwiftData faulting during
scroll.

1. **Introduce a lightweight row type.**
   `struct CardRow: Sendable, Hashable, Identifiable { uuid, title,
   frontImageID, hasStereoDetections }`. This is what grids render. Add
   `CatalogQueryService.cardRows(matching:sortBy:offset:limit:)` that fetches
   with `propertiesToFetch` and returns `[CardRow]` off the main actor.
2. **Page by offset, append, never refetch the prefix.**
   Replace `PagedCardGridView`'s growing `fetchLimit` with a `@State
   var rows: [CardRow]` that appends pages of 60–120 as the user nears the
   end. `LibraryView`, `YearCardsView`, and the four relationship grids all
   use this one paged source. Search keeps its debounce and resets the pages.
3. **Kill the linear scans.**
   `CardGridView` iterates `rows.indices` (or `enumerated()`) and passes the
   index into the cell; drop `firstIndex(where:)`. Prefetch ahead uses the
   index directly.
4. **Card list context by identity.**
   `CardListContext` holds `[String]` of UUIDs plus `[String: Int]` index map,
   not `[StereoCard]`. `CardPagerView` resolves the current card with an
   indexed UUID fetch and only materializes the current page ±1 as models.
   `SpatialPhotoViewModel` does the same.
5. **Favorites and albums.**
   `ModelContext.cards(matching:)` returns `[CardRow]` via the query service;
   the detail view fetches the full model on demand.
6. **Measure.** Instruments (SwiftUI + Core Data templates) on iPad Pro and
   Vision Pro before and after; record hitch rate in this file.

Done when: Library first render < 300 ms after container load; zero SwiftData
faults during a scroll of 500 rows; hitch rate < 1% at 120 Hz on iPad Pro.

---

## Phase 3 — Restoration quality track (ongoing, start after Phase 1)

Status: 3.1 (evaluation set, debug eval tool, golden test) and 3.2
(resolution tiers, downscaled rectification analysis) shipped on
`fall-2026-revision`. The 45-card set in
`Stereologue/Fixtures/restoration-eval.json` was auto-selected from measured
per-eye statistics on 725 sampled cards; no NYPL scan has digitally clipped
pixels, so "blown" ranks by bright-pixel fraction instead. Confirm categories
visually in the Restoration Eval tool (Library toolbar, debug builds). Golden
renders live in `StereologueTests/Fixtures/`; re-record per the comment on
`toneStylesMatchGoldenRenders`. Next: 3.3 spike (needs a Python toolchain
with torch + coremltools, not present on this machine).

There is currently no defect-repair stage in the app. This phase builds one
from measurement up.

Principle: **the second eye is the reference.** Any step that generates pixels
must be applied with the same mask to both eyes or verified against the
sibling, so nothing ends up in one eye that isn't in the other. No whole-image
generative models (Bringing Old Photos global stage, GFPGAN, CodeFormer,
diffusion restorers) — they hallucinate independently per eye and break
stereo fusion.

1. **Evaluation set first (½ day).**
   Pick ~40 cards spanning: clean, dusty, scratched, blown highlight on one
   eye, faded/sepia, uneven lighting, hand-tinted. Store UUIDs in
   `StereologueTests/Fixtures/restoration-eval.json`. A debug menu renders any
   style/depth for these and writes PNGs to a folder for side-by-side review.
   Add a golden-image test that flags a > 2% mean pixel change against the
   committed output so regressions are visible.
2. **Resolution tiers (1 day).**
   Preview tier: crop → downscale to ≤ 1024 px per eye → tone → rectify. This
   is what the viewers show by default and what prefetch uses. Full tier: full
   resolution, plus defect repair once it exists, on explicit request only.
   Rectification registration (and any future disparity matching) runs on
   ≤ 640 px copies; the transform / field is upsampled and applied at full
   size.
3. **Learned scratch detector (2–3 days, spike first).** — 🔬 spike done, verdict open
   Spike results (`tools/scratch-detector/`, run with uv): the U-Net converts
   to Core ML (FP16, 72 MB, static 256 or 512 px input — flexible shapes
   crash the Core ML CPU backend on macOS 26.6) and matches PyTorch to
   ≥ 0.99 IoU. Neural Engine time on an M-series Mac: 33 ms at 256, 130 ms
   at 512 per eye, so the < 1 s Vision Pro budget is safe. Quality is
   unproven on this collection: on the auto-selected eval cards it flags
   print borders and thin bright scene lines (cane stalks, pipes), and mask
   density separates "defects" from "clean" cards only ~1.5× with large
   per-card variance. Decide with human-marked scratches: the Restoration
   Eval tool has a Scratch mask overlay with a threshold slider (load the
   model from the app's Documents folder; it is not bundled). A 6 % border
   exclusion and a higher threshold (0.6–0.8) are the first knobs to try.
   Convert only the scratch-detection U-Net from *Bringing Old Photos Back to
   Life* (MIT-licensed code and checkpoints) to Core ML via coremltools; fp16,
   fixed 512 px input, run on a downscaled eye and upsample the mask. Compare
   against a multi-scale morphological top-hat baseline on the eval set (the
   removed single-radius detector is the floor, not the baseline). Spike exit
   criteria: converts, runs on Vision Pro in < 1 s per eye, and its masks
   cover the scratches a human marks on the eval set with few false positives
   on texture. Ship the detector only together with a fill (3.4).
3b. **Disparity-aware sibling fill (2 days).**
   Reinstate the sibling-fill idea from the removed `StereoPairProcessor`,
   but replace general optical flow with matching constrained to the epipolar
   line after rectification: for each masked pixel, block-match horizontally
   in the other eye within the card's disparity range, accept on a
   left-right consistency check, and fill; feather the result. Highlight
   recovery uses the same match.
4. **Fallback inpainting (2–3 days, macOS first).**
   For pixels the sibling can't resolve (match rejected or both eyes
   damaged), use LaMa via Core ML
   (see `mallman/CoreMLaMa`). Mask-conditioned only. Apply with the *union*
   mask to both eyes so the fill is stereo-consistent. Validate on macOS;
   iPad and Vision Pro need ANE/fp16 tuning and may stay on the classical
   fill.
5. **Optional grain reduction (later).**
   If still wanted, NAFNet-small (convolutional, converts cleanly). Same
   strength on both eyes, off by default. Do not revisit transformer
   denoisers.
6. **Tone pipeline stays classical.** It is deterministic and identical per
   eye. Expose the five tone-curve points and CLAHE clip limit as user
   sliders in the wiggle/spatial viewers if adjustment is wanted.

---

## Phase 4 — Kernels to Accelerate / Core Image (3–5 days)

Goal: the classical passes run in tens of milliseconds at full resolution, in
Debug and Release, on Vision Pro.

- Histograms and LUT application: `vImageHistogramCalculation_ARGB8888`,
  `vImageTableLookUp_ARGB8888`.
- Per-pixel luminance ratio scaling (stretch, auto-exposure, affine match):
  `vDSP` on a planar float luminance buffer, then `vImage` multiply.
- CLAHE: keep the algorithm, move the per-tile CDF apply to a Metal compute
  kernel or a `CIKernel`; tile CDFs become a 2D texture.
- Morphology (defect detector): `vImageMin_PlanarF` / `vImageMax_PlanarF`.
- Box blur / feather: `vImageBoxConvolve_PlanarF`.
- Dilate: `vImageDilate_PlanarF`.
- Homomorphic illumination field: `CIGaussianBlur` on a downscaled log-luma,
  or keep the block-average and vectorize with `vDSP_vadd`.
- Optical flow sampling / inpaint loops: `withUnsafeMutableBufferPointer` +
  SIMD, and `DispatchQueue.concurrentPerform` over row bands.

Order by profile: run every style at full resolution on the eval set under
Instruments, convert the top three time sinks first, re-profile.

---

## Phase 5 — Housekeeping (1 day)

- Remove `predictions_with_metadata.parquet` from the app target's Resources
  (it is 8.4 MB shipped for nothing). Keep it in the repo next to
  `convert_parquet.py`.
- Move `Tools/CatalogStoreMigrator.swift` and `Tools/PlaceDuplicateFinder.swift`
  out of the app target into a `StereologueTools` command-line target or the
  test target.
- Untrack `CatalogStore.store-shm` / `-wal`; add to `.gitignore`.
- Delete the empty `CoreML/` folder.
- Unit tests for pure logic: crop rect math and clamping, `matchDimensions`,
  cache variant keys (including crop hash), `safeShareFilename`, `YearGroup`
  counting, `cards(matching:)` ordering.
- Update `ARCHITECTURE.md`: `RestorationPipeline` is a Sendable class, not an
  actor; describe the renderer/cache split from Phase 1 and the row-type data
  source from Phase 2; add the "second eye is the reference" rule.

---

## Sequencing

| Order | Phase | Why now |
|---|---|---|
| 1 | Phase 1 | Removes the hang; smallest change, biggest user impact |
| 2 | Phase 2 | Scrolling is the second complaint; independent of restoration |
| 3 | Phase 3.1–3.2 | Eval set and tiers make every later restoration change measurable |
| 4 | Phase 5 | Cheap, and the test scaffolding helps 3 and 4 |
| 5 | Phase 3.3 | Detector spike; decide go/no-go on the learned mask |
| 6 | Phase 4 | Only matters once the eval set exists to measure against |
| 7 | Phase 3.3b–3.6 | Sibling fill, inpainting fallback, optional passes |

## Out of scope for this revision

- CloudKit sync (entitlement still pending).
- Porting the global-restoration or face-enhancement stages of Bringing Old
  Photos Back to Life, or any diffusion-based restorer.
- macOS menu commands, accessibility labels (tracked in `ARCHITECTURE.md`).
