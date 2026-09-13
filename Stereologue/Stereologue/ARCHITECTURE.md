# Stereologue — Architecture

Stereologue is a multi-platform SwiftUI app (iPadOS, macOS, visionOS) for
browsing and viewing the New York Public Library's stereoscopic photograph
collection. This document describes how the app is organized, the trade-offs
behind its key design choices, and the conventions to follow when extending it.

For the image-restoration pipeline specifically, see
`stereoview-restoration-guide.md` in this folder.

---

## Targets and platform support

| Target               | Purpose                                  |
| -------------------- | ---------------------------------------- |
| `Stereologue`        | The app. Deploys to iOS 26 / macOS 26 / visionOS 26. |
| `StereologueTests`   | Unit tests (Swift Testing framework).    |
| `StereologueUITests` | UI tests (XCUIAutomation).               |

The Swift Language Version is **Swift 6**, with strict concurrency enforced as
errors. The build also sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
**every type and method is implicitly `@MainActor` unless explicitly marked
`nonisolated`** (or declared as an `actor`). See "Concurrency model" below.

---

## Layered architecture

```
┌─────────────────────────────────────────────────────────┐
│                       Views (SwiftUI)                   │
│   ContentView, CardDetailView, SpatialPhotoView, …      │
└──────────────┬──────────────────────────────┬───────────┘
               │                              │
   reads via @Environment             builds Sendable
   / @Query                           snapshots
               │                              │
┌──────────────▼──────────┐    ┌──────────────▼───────────┐
│   Services (actors +    │    │  Models (@Model classes  │
│   @Observable classes)  │    │  + Sendable value types) │
│                         │    │                          │
│   UserDataService       │    │  StereoCard, Creator,    │
│   SpatialPhotoService   │    │  Subject, Place, …       │
│   RestorationPipeline   │    │  UserAlbum, UserFavorite │
│   StereoRectification…  │    │  UserNote, UserCrop…     │
└──────────────┬──────────┘    └──────────────┬───────────┘
               │                              │
               └────────┬─────────────────────┘
                        │
              ┌─────────▼──────────┐
              │  SwiftData stores  │
              │ (two containers)   │
              └────────────────────┘
```

Views never talk to SwiftData containers directly. They read models through
`\.modelContext` (catalog) and `\.userModelContext` (user data), and mutate
through `UserDataService`.

---

## Two-container SwiftData design

Stereologue uses **two separate `ModelContainer`s**, not one. Both are set up
in `ModelContainerSetup.swift` and wired in `StereologueApp.swift`.

### Catalog container

- **Schema:** `StereoCard`, `Creator`, `Subject`, `Place`, `Collection`
- **Storage:** Local SQLite, **pre-built and bundled in the app** as
  `CatalogStore.store`. On first launch, copied into
  `~/Library/Application Support/Stereologue/`.
- **CloudKit:** None.
- **Versioning:** A `UserDefaults` key (`CatalogStoreVersion`) tracks the
  store schema version. When the bundled store moves to a new version,
  `CatalogStoreMigrator.swift` rebuilds the local copy.
- **Size:** ~41 000 cards, with `#Index` on `uuid`, `yearStart`, `yearEnd`,
  and `division` for fast browsing.
- **Bound to:** `\.modelContext` (via `.modelContainer(...)` at the
  `WindowGroup`).

### User container

- **Schema:** `UserAlbum`, `UserAlbumEntry`, `UserFavorite`, `UserNote`,
  `UserCropOverride`
- **Storage:** Local SQLite in `~/Library/Application Support/Stereologue/`,
  CloudKit-ready (currently `.none`; flip on once the entitlement is added).
- **Bound to:** `\.userModelContext` (a custom `EnvironmentKey`).

### Why two containers?

1. The catalog is read-mostly bulk data. Shipping it pre-built avoids a slow
   first-launch import and keeps the SQLite file's page layout optimal.
2. CloudKit-synced data should be **only** what the user creates. If the
   catalog and user data shared a container, every catalog update would
   churn CloudKit; conversely, every CloudKit ingest would mix into the
   catalog schema.
3. The two schemas can evolve independently.

### Cross-container references

User-data records reference catalog rows by **`cardUUID: String`**, never by
SwiftData relationship — because SwiftData relationships cannot cross
containers. Favorites and album grids resolve the strings into `CardRow`s via
`CatalogQueryService.cardRows(uuids:)` (off the main actor, order preserved);
the detail pager resolves a single `StereoCard` on the main context with
`ModelContext.cards(matching:)`.

### Bootstrap & fallback

`StereologueApp.init()` constructs both containers, catches
`ContainerSetupError`, and falls back to in-memory containers with a
user-facing alert. The app remains usable but data won't persist — this
prevents a "broken-on-launch" experience when storage is unavailable.

---

## Services

All services are injected via `@Environment`. None of them are singletons.

### `UserDataService` — `@Observable @MainActor` class

Owns all writes to the user container (favorites, notes, crop overrides,
albums). The only place that calls `userContext.save()`. Exposes:

- `lastError: UserDataError?` for the global error alert
  (`.userDataErrorAlert()` modifier).
- `albums: [UserAlbum]` — reactively republished via a
  `ModelContext.didSave` notification observer on the user container.

Why publish `albums` here instead of `@Query` in `ContentView`?
**`@Query` reads from `\.modelContext`, which the app reserves for the
catalog container.** SwiftData provides no per-Query container override, so
this service publishes the reactive list itself. The result is identical to
what `@Query` would do (auto-update on create/delete/CloudKit sync), without
fighting the environment.

### `SpatialPhotoService` — `actor` (cache + coalescing only)

The front door for every stereo render. It owns *only* cheap state — the
bounded in-memory HEIC cache (16 variants), the share directory, and the map
of in-flight renders — and delegates all pixel work to `StereoPairRenderer`,
so a cache hit or a new request for card B never queues behind a slow render
of card A.

- **Cache key** = `<uuid>_<quality>_<cropKey>_<tier>[_<style>]`. Every input
  that changes pixels is in the key, including the effective crop geometry,
  so a user crop edit can never hit a stale entry (no explicit eviction needed).
- **Coalescing with reference counting.** Concurrent requests for one variant
  share one `Task`. Each waiter is counted; when the last waiter's task is
  cancelled the render is cancelled too, and a cancelled caller gets
  `CancellationError` rather than stale data.
- **Prefetch** (`prefetch(cards:…)`) always renders the preview tier at
  `.utility` priority.
- **Sendable boundary.** Takes `SpatialPhotoCardData`, never a `StereoCard`.
- **Share path** (`shareableSpatialPhotoURL`) renders at full tier, embeds
  IPTC/TIFF metadata, and is the only path that writes a file.

### `StereoPairRenderer` — `nonisolated struct`, `@concurrent`

The pure pipeline:

```
download (Nuke) → crop L/R → [preview: downscale] → tone restore (both eyes,
concurrently) → exposure match → rectify → dimension match → HEIC encode
```

Every async entry point is `@concurrent`, so it runs on the global executor
regardless of the calling actor, and it checks `Task.isCancelled` between
stages. `RenderTier.preview` downscales both eyes by one shared factor to at
most 1024 px wide before any pixel work; `.full` keeps source resolution and
is used for sharing and on explicit request.

### `RestorationPipeline` — `nonisolated final class`, Sendable

Tone and contrast restoration in three intents (`RestorationStyle`):
`enhance` (auto white balance, per-channel stretch, auto exposure, CLAHE,
tone curve), `preserveTone` (luminance-only stretch/exposure/CLAHE so sepia
and hand-tinting survive), and `evenLighting` (homomorphic illumination
flattening). Each intent reads pixels once, runs its CPU stages in place, and
writes back once. `matchPair` evens overall brightness between the eyes with a
global affine luminance remap, which preserves parallax. It's a Sendable class
(not an actor) so the two eyes restore concurrently. Golden-image tests pin
its output (see "Debug tooling").

There is currently **no** dust/scratch repair stage; see
`PLAN-fall-2026.md` Phase 3 and the history note in
`stereoview-restoration-guide.md`.

### `StereoRectificationService` — `nonisolated final class`, Sendable

Removes vertical offset and in-plane tilt between the eyes while leaving
horizontal parallax alone. Deliberately **not** a homography (that would
cancel the depth cue). Estimates translation with Vision's translational
registration on ≤ 640 px copies (tilt from the difference between the two
half-frames), scales the shift back up, and applies vertical + rotation only.

### `CLAHEProcessor` — `nonisolated struct`

Pure-value contrast-limited adaptive histogram equalization operating in
place on an RGBA8 buffer. `nonisolated` so the (otherwise-MainActor-by-default)
struct is callable from `RestorationPipeline` off the main actor.

### `ImagePipelineConfig` — Nuke configuration

Configures the shared Nuke pipeline (`ImagePipeline.shared = .stereologue`):
100 MB memory cache, 500 MB disk cache, dedup, progressive decoding off
(NYPL IIIF returns complete JPEGs).

### `CatalogQueryService` — `@ModelActor`

Runs catalog reads on a **background** `ModelContext` so browsing never blocks
the main actor. Backs every card grid (paged rows), the mosaic tiles in the
Subjects/Creators/Places/Collections lists, and the year counts.

Key points:
- **Paged rows.** `cardRows(matching:sortBy:offset:limit:)` returns one page
  of `CardRow` values for any predicate (`nil` = whole catalog); the sort must
  be a total order (grids end it with `uuid`). A `#Index` on `title` keeps
  title-ordered pages deep into the catalog cheap. `cardRows(uuids:)` resolves
  a UUID list in the caller's order (favorites, albums).
- **Returns Sendable values only.** `previewImageURLs(matching:quality:limit:)`
  runs a bounded (`fetchLimit`-4) fetch and returns `[URL]` — never a `@Model`.
  Tiles render from the URLs; the prefetcher warms upcoming rows the same way.
- **Reading `@Model` off-main.** Because the project defaults to MainActor
  isolation, the five catalog models are marked `nonisolated` (see below) so
  this actor's context can read them. Instances stay local to the actor's
  context — they are never shared across actor boundaries.
- **Count backfill.** `backfillCardCounts()` populates each browse entity's
  denormalized `cardCount` once per install (guarded by a `UserDefaults` flag,
  triggered from `StereologueApp`). It faults each relationship a single time,
  off the main actor. Future stores are rebuilt with counts already baked in by
  `CatalogStoreMigrator`, so the badge needs **no** per-tile count query.

---

## Models

### Catalog models

`StereoCard` is the central catalog model. It owns:

- Identity: `uuid` (unique), title, physical form, division.
- Dates: `dateStartRaw` / `dateEndRaw` strings + parsed `yearStart` /
  `yearEnd` ints (indexed for browsing).
- Relationships: `creator` (one), `subjects` / `places` (many), `collection`
  (one).
- IIIF image IDs and known pixel dimensions.
- `leftDetection` / `rightDetection` as **embedded** `ImageDetection`
  (a `CompositeAttribute` — SwiftData flattens its fields into the parent
  table, no join).

`ImageDetection` is `Codable, Hashable, Sendable`, and its `init` is marked
`nonisolated` so the `@Model` macro's synthesized initializers (which run
nonisolated) can use it as a default value.

The browse entities — `Subject`, `Creator`, `Place`, `Collection` — each carry
a **stored** `cardCount: Int` (denormalized; populated at import/migration and
backfilled on first launch). Reading it costs nothing, so mosaic tiles show the
count badge without an unbounded per-tile aggregate query. All five catalog
models (`StereoCard` + the four browse entities) are declared `nonisolated` so
`CatalogQueryService`'s background context can read them; MainActor code is
unaffected.

### User models

All five user models include a `cardUUID: String` referencing a catalog row.
`UserFavorite`, `UserNote`, and `UserCropOverride` are 1-to-N keyed by
`cardUUID`. `UserAlbum` owns `UserAlbumEntry` rows via a cascade-delete
SwiftData relationship.

### Snapshots and rows

`SpatialPhotoCardData` is the Sendable boundary type that crosses from
MainActor view code into the `SpatialPhotoService` actor. Build with
`StereoCard.spatialPhotoData(cropOverride:)`. Never pass a `@Model` directly
across an actor hop.

`CardRow` (uuid, title, front image ID, stereo flag) is what grids, the
thumbnail strip, the pager, and the spatial viewer's list hold. Grids never
iterate `[StereoCard]`: the Library used to materialize all 41K models on the
main context, and every identity or index lookup faulted rows on the main
thread. Now `PagedCardRows` appends pages of 80 rows fetched off-main,
`CardListContext` carries the on-screen grid's rows plus a UUID→index map, and
only the page actually on screen (`CardPage` in `CardPagerView`) resolves its
`StereoCard` by an indexed UUID fetch.

---

## Concurrency model

The project relies on three Swift 6.2 features:

1. **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** — types and methods are
   `@MainActor` by default. Views, services, and value types all inherit
   MainActor isolation unless they opt out.
2. **`nonisolated`** — used on:
   - `ImageDetection.init` so SwiftData's nonisolated macro code can use it.
   - `CLAHEProcessor`, `RestorationPipeline`, `StereoRectificationService`,
     and `StereoPairRenderer` so the render pipeline runs off the main actor.
   - `SpatialPhotoCardData`, `CardRow`, `RenderTier`, and the other value
     types that cross actor boundaries.
   - `Codable` conformance methods on `ImageDetection` (`init(from:)` and
     `encode(to:)`).
   - The five catalog `@Model` classes (`StereoCard`, `Subject`, `Creator`,
     `Place`, `Collection`) so `CatalogQueryService`'s background `@ModelActor`
     context can read them.
   - The `CardCountable` protocol requirements (class-bound) so the generic
     count backfill can run off the main actor.
3. **`actor`** — used only where there is mutable state to serialize:
   `SpatialPhotoService` (caches, in-flight map) and `CatalogQueryService`
   (a `@ModelActor` owning a background `ModelContext`). Pixel pipelines are
   `nonisolated` Sendable classes/structs whose only state is a thread-safe
   `CIContext`, and their async entry points are `@concurrent` so they never
   run on the calling actor. Long renders check `Task.isCancelled` between
   stages.

### Crossing actor boundaries

Rules of thumb:

- **Never pass a `@Model` *instance* across an actor hop.** Build a `Sendable`
  snapshot on MainActor first (see `spatialPhotoData(cropOverride:)`). A
  `@ModelActor` is the exception to *reading* the catalog off-main: it fetches
  its own instances in its own context and returns Sendable values (`[URL]`,
  counts) — instances never leave the actor.
- **Never pass a live `ModelContext` to an actor.** Give a `@ModelActor` the
  `ModelContainer` (it derives a private background context), or use
  `UserDataService` (MainActor-isolated) for writes and pass plain values.
- **`nonisolated(unsafe)`** is used exactly once, for the shared Nuke
  `ImagePipeline.stereologue` static — `ImagePipeline` is internally
  thread-safe and the property is initialized in `StereologueApp.init()`
  before any other code touches it.

---

## Navigation

`ContentView` uses a single `TabView(.sidebarAdaptable)`. Six static tabs
(Library, Favorites, Dates, Subjects, Creators, Places, Collections) plus
a `TabSection("Albums")` whose tabs are produced by iterating
`userDataService.albums`.

Each tab wraps its content in a `NavigationStack` with
`.cardNavigationDestinations()` applied once at the root. That extension
registers value-based destinations for `CardRow`, `Subject`, `Creator`,
`Place`, and `Collection` — link to those values anywhere in the hierarchy
and they push the right view. A `CardRow` pushes `CardPagerView`, which pages
through the originating grid's rows.

`AppTab` is the selection type. `AppTab.album(UUID)` covers the dynamic
album tabs.

---

## Dependency injection

Wired at the `WindowGroup` in `StereologueApp.body`:

| What                             | How                                                     |
| -------------------------------- | ------------------------------------------------------- |
| Catalog container                | `.modelContainer(catalogContainer)`                     |
| User context                     | `.environment(\.userModelContext, ...)`                 |
| `UserDataService`                | `.environment(userDataService)`                         |
| `SpatialPhotoService`            | `.environment(\.spatialPhotoService, ...)`              |
| `CatalogQueryService`            | `.environment(\.catalogQueryService, ...)`              |
| `SpatialPhotoViewModel` (visionOS) | `.environment(spatialPhotoViewModel)`                |

`CardListContext` (an `@Observable` holding the current grid's card list so
`CardPagerView` can swipe through siblings) is set inside `ContentView` and
scoped to the tab view.

---

## Image pipeline (Nuke)

Nuke is the only third-party dependency, used for downloading catalog
images. Configured in `Services/ImagePipelineConfig.swift`; the shared
`ImagePipeline.shared` is replaced with the Stereologue-tuned instance
in `StereologueApp.init()` *before any view runs*.

Views use `LazyImage` from `NukeUI`. The `SpatialPhotoService` actor uses
`pipeline.image(for:)` directly to download source images for HEIC
generation (and benefit from Nuke's disk cache).

---

## Debug tooling

Debug builds only (`#if DEBUG`):

- **Restoration Eval** (Library toolbar; its own window on macOS, a sheet
  elsewhere). Renders any card of the evaluation set at any style and tier
  beside its original, exports every style as PNG, and can overlay a
  scratch-detector mask. The evaluation set — 45 cards in nine categories,
  auto-selected from measured image statistics — is
  `Fixtures/restoration-eval.json`; a test checks every card exists in the
  catalog.
- **Golden renders.** `StereologueTests/Fixtures/` holds four 512 px eye
  crops and one golden per tone style; `toneStylesMatchGoldenRenders` fails on
  more than 2 % mean pixel drift. Re-record per the comment on that test.
- **`ScratchDetector`** loads a Core ML model from the app's Documents folder
  (never bundled). The conversion lives in `tools/scratch-detector/`; the
  detector is paused — see the plan.
- **`Tools/`** (`CatalogStoreMigrator`, `PlaceDuplicateFinder`) are offline
  curation tools compiled only in Debug.

Restoration principle: **the second eye is the reference.** Anything that
generates pixels must be applied identically to both eyes or verified
against the sibling; no per-eye generative models.

## Adding a new feature: checklist

When adding a new model or feature, walk through:

1. **Which container does it belong to?** Catalog (read-mostly,
   bulk-imported) or user (writeable, eventually CloudKit-synced)?
2. **Reference, not relationship.** If it crosses containers, store
   `cardUUID: String`.
3. **Writes go through `UserDataService`.** Don't call `userContext.save()`
   from a view.
4. **Reactive lists.** Use `@Query` for catalog reads. For user-container
   lists, either add a published property on `UserDataService` (see
   `albums`) or expose via `\.userModelContext` and `@Query` inside a
   wrapper view.
5. **Actor boundaries.** If you call into an actor, snapshot the model
   into a Sendable value first.
6. **Errors.** Throw a `UserDataError` from `UserDataService`, or a custom
   `LocalizedError` from an actor service. Either way, surface via the
   existing alert plumbing rather than printing.
7. **Previews.** Use `.previewEnvironment()` from `PreviewSampleData.swift`
   so both containers are wired up.

---

## Known limitations / future work

- **CloudKit sync is gated behind an entitlement.** Infrastructure is in
  place in `ModelContainerSetup.swift`; flip the user container's
  configuration to `.private(...)` once the entitlement ships.
- **Accessibility.** Dynamic Type scaling and VoiceOver labels on
  thumbnails are still TODO.
- **macOS menu commands.** No `.commands { ... }` on the main scene yet —
  desktop users have no menu-bar shortcuts.
- **Test coverage.** `StereologueTests` covers the tone pipeline (goldens),
  cache keys, crop geometry, paging (against a copy of the bundled store,
  which also exercises its lightweight migration), and year counts.
  `UserDataService` and the migrator remain untested.
- **Restoration roadmap.** Kernel vectorization and the defect-repair track
  are planned in `PLAN-fall-2026.md` (Phases 3–4).
