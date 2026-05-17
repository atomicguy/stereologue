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
containers. `AlbumDetailView.loadCards` resolves the strings into
`StereoCard`s by fetching from the catalog context.

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

### `SpatialPhotoService` — `actor`

Converts NYPL card scans into spatial HEIC files (visionOS) and cropped
stereo pairs (flat-screen wiggle/anaglyph views). Pipeline:

```
download (Nuke) → crop L/R → optional restoration → rectify → resize → HEIC write
```

Key invariants:
- **Cache.** Outputs are written to `~/Library/Caches/Stereologue/SpatialPhotos/`
  keyed by `<uuid>[_restored_<style>].heic`. Cache hits return immediately.
- **Coalescing.** Concurrent calls for the same cache key are merged into
  one in-flight `Task<URL, Error>` via `inFlightTasks: [String: Task<...>]`.
- **Sendable boundary.** The actor takes a `SpatialPhotoCardData` struct,
  **not** a `StereoCard`. `@Model` classes are MainActor-bound and not
  Sendable; the snapshot is built on MainActor via
  `card.spatialPhotoData(cropOverride:)`.
- **Shareable variant.** `shareableSpatialPhotoURL(for:metadata:)` regenerates
  every time and embeds IPTC/TIFF metadata (title, creator, places, etc.) so
  recipients see the card's info.

### `RestorationPipeline` — `actor`

Tone and contrast restoration for scanned prints. CLAHE + sepia
neutralization + tone curve + optional luminance transfer. Uses a Metal-backed
`CIContext` when available, CPU `CIContext` as fallback. See
`stereoview-restoration-guide.md` for the underlying algorithm.

### `StereoRectificationService` — `actor`

Corrects vertical misalignment between left/right images using Vision's
homography. Falls back to a translational alignment if the homography is
unreasonable (corners distort > 30%).

### `CLAHEProcessor` — `nonisolated struct`

Pure-value contrast-limited adaptive histogram equalization. `nonisolated`
so the (otherwise-MainActor-by-default) struct is callable from any actor
that owns a `CIContext` — currently `RestorationPipeline`.

### `ImagePipelineConfig` — Nuke configuration

Configures the shared Nuke pipeline (`ImagePipeline.shared = .stereologue`):
100 MB memory cache, 500 MB disk cache, dedup, progressive decoding off
(NYPL IIIF returns complete JPEGs).

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

### User models

All five user models include a `cardUUID: String` referencing a catalog row.
`UserFavorite`, `UserNote`, and `UserCropOverride` are 1-to-N keyed by
`cardUUID`. `UserAlbum` owns `UserAlbumEntry` rows via a cascade-delete
SwiftData relationship.

### Snapshots

`SpatialPhotoCardData` is the Sendable boundary type that crosses from
MainActor view code into the `SpatialPhotoService` actor. Build with
`StereoCard.spatialPhotoData(cropOverride:)`. Never pass a `@Model` directly
across an actor hop.

---

## Concurrency model

The project relies on three Swift 6.2 features:

1. **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** — types and methods are
   `@MainActor` by default. Views, services, and value types all inherit
   MainActor isolation unless they opt out.
2. **`nonisolated`** — used on:
   - `ImageDetection.init` so SwiftData's nonisolated macro code can use it.
   - `CLAHEProcessor` (struct) so the actor `RestorationPipeline` can call it.
   - `SpatialPhotoCardData` (struct) so it's freely usable inside the actor.
   - `Codable` conformance methods on `ImageDetection` (`init(from:)` and
     `encode(to:)`).
3. **`actor`** — used for `SpatialPhotoService`, `RestorationPipeline`,
   `StereoRectificationService`. Each owns serial state (caches, in-flight
   task maps, `CIContext`s) and exposes async methods.

### Crossing actor boundaries

Rules of thumb:

- **Never pass a `@Model` class to an actor.** Build a `Sendable` snapshot
  on MainActor first (see `spatialPhotoData(cropOverride:)`).
- **Never pass a `ModelContext` to an actor.** Use `UserDataService`
  (MainActor-isolated) for writes; pass extracted plain values to actors.
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
registers value-based destinations for `StereoCard`, `Subject`, `Creator`,
`Place`, and `Collection` — link to those values anywhere in the hierarchy
and they push the right view.

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
- **No cancellation support in image services.** Long-running restoration
  or rectification can't be interrupted by a view dismiss.
- **Accessibility.** Dynamic Type scaling and VoiceOver labels on
  thumbnails are still TODO.
- **macOS menu commands.** No `.commands { ... }` on the main scene yet —
  desktop users have no menu-bar shortcuts.
- **Test coverage.** `StereologueTests` skeletons exist; concrete coverage
  of `UserDataService`, `CatalogStoreMigrator`, and the restoration golden
  images are the highest-leverage gaps.
