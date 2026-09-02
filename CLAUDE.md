# Working in this repository

Guidance for Claude Code (and anyone else) working on this project.
See `README.md` for the science; this file covers how the repo is set up and the conventions to follow when changing it.

## What this is

A `targets` pipeline that builds a connectivity map of old-forest intactness for the Quesnel Natural Resource District, and runs it through [Omniscape](https://github.com/Circuitscape/Omniscape.jl).
It is an analysis project, not an R package.

- `_targets.R` -- the pipeline definition
- `R/` -- all pipeline functions, loaded by `targets::tar_source()`
- `tests/testthat/` -- standalone `testthat` suite (see [Tests](#tests))
- `scripts/` -- diagram generators and one-off utilities, not part of the pipeline
- `Omniscape/` -- generated Omniscape configs and launch scripts

`Data/`, `Outputs/`, `Teams/`, and `_targets/` hold inputs, results, and the `targets` store.
They are not tracked in git, and the pipeline creates them as plain directories if they do not exist.

Making them **symlinks is optional** -- a convenience for putting the bulky parts somewhere other than the clone, e.g. network storage or a larger local volume, and for sharing one copy of the data and the `targets` store between machines or collaborators.
`scripts/symlinks.sh` sets up the layout used here; edit the paths in it, or skip it entirely and let the pipeline create local directories.
Nothing in the code assumes symlinks or any particular location -- paths all go through `get_path()`.

## Environment

- **R** is pinned by `renv` (see `renv.lock`).
  Several R versions are installed side by side via [rig](https://github.com/r-lib/rig); use the version `renv.lock` names, not whatever `R` resolves to on `PATH`.
  `renv/library/` is per R minor version, so running under the wrong one looks like a completely empty library.
- **Julia** is managed by [juliaup](https://github.com/JuliaLang/juliaup).
  Omniscape does not work on Julia 1.12 ([Omniscape.jl#160](https://github.com/Circuitscape/Omniscape.jl/issues/160)) -- use 1.11.x, which `run_omniscape()` selects explicitly via a `+version` channel argument.
- **Never attach packages in `.Rprofile`.**
  It runs *before* R attaches the default packages, so anything attached there lands **below** `stats` on the search path -- and `library()` on an already-attached package is a no-op, so a later `library(dplyr)` cannot lift it back up.
  A bare `filter()` then silently resolves to `stats::filter()` and fails with an unrelated-looking error (`'list' object cannot be coerced to type 'double'`).
  A bare `library()` there also breaks a fresh clone, where the project library is empty until `renv::restore()` runs.
- **Use qualified calls (`dplyr::filter()`) in `R/`.**
  Nothing is attached, by design; see above.
- **Worker settings belong in `.Rprofile`, not `_targets.R`.**
  `crew` workers start their own R sessions: they load `.Rprofile` but never source `_targets.R`.
  Anything set only in `_targets.R` (thread limits, `terra::terraOptions()`) silently applies just to the session that *defines* the pipeline, and the workers run with defaults.

## Running the pipeline

```r
targets::tar_make()
```

Environment variables (documented in `README.md`): `BC_CONN_WORKERS`, `BC_CONN_JULIA_THREADS`, `BC_CONN_OMNISCAPE`.
Omniscape runs are opt-in because a single one can take days and hundreds of GB of RAM.

This is a shared machine.
Check free RAM, load average, and what else is running before starting a long job, and cap `BC_CONN_WORKERS` accordingly rather than taking every core.

## Tests

```r
targets::tar_source()
testthat::test_dir("tests/testthat")
```

The suite is deliberately built around cases with **closed-form answers** -- concentric seral rings whose interior-forest areas can be computed by hand, patches at known separations -- because the bugs this pipeline has had were all of the kind that produce plausible-looking wrong numbers rather than errors.
When fixing a bug here, add the case that pins it, and check it fails without the fix.

Tests must not write into `Data/` or `Outputs/`.
Functions that write files take an output-directory argument defaulting to the real location, so tests can point them at `withr::local_tempdir()`.

## Spatial conventions

These are all things that have silently produced wrong numbers in this project.
Prefer the stated option unless there is a specific reason not to.

- **`terra` over `sf` for polygon work.** terra's overlay operators are GEOS-backed and vectorised in C++, and `terra::intersect()` / `terra::erase()` split geometries at the overlay boundaries and carry the attribute sets through, which is what the arcpy scripts this project ports rely on.
- **Never use `terra::union()`.**
  Its documented semantics are exactly the arcpy `Union_analysis` ones, which is why it was reached for three separate times here, and it is wrong every time on real geometry.
  It returns output polygons that overlap one another *and* a dissolved footprint smaller than its input, so it double-counts some land while dropping other land outright -- in opposite directions, which is what makes the totals look plausibly rather than obviously wrong.
  Measured on the VRI x NDT-BEC overlay it dropped 22,628 ha and double-counted 15,449 ha; on a 2,933-polygon window of the final resultant it overlapped itself by 303 ha and dropped 82 ha.
  It is also superlinear -- 418x slower than the equivalent on one study-area tile, 28.5x on another, and one target ran 25 h before being killed.
  Use `overlay_left_join()` in `R/data_prep.R` for a left join, and `terra::intersect()` for an inner one; both partition the left-hand layer exactly.
  Synthetic fixtures do *not* reproduce the failure, so a passing unit test is not evidence that a `union()` is safe.
  Reported upstream as [rspatial/terra#2175](https://github.com/rspatial/terra/issues/2175); it reproduces on terra 1.8.86 and 1.9.34 under both R 4.5.3 and R 4.6.1, so upgrading is not a fix.
- **Do not use `terra::erase()` either; use `erase_polygons()` in `R/data_prep.R`.**
  It can return a `SpatVector` with more attribute rows than geometries: a polygon whose difference comes out empty loses its geometry but keeps its row.
  Nothing complains at the time, and whatever next reads the attributes fails instead, a long way from the cause -- one run got six hours in before dying on `[[<-,SpatVector] cannot add these values`.
  It hit 5 of 49 tiles of the seral overlay, each off by exactly one row.
  Reported as [rspatial/terra#2179](https://github.com/rspatial/terra/issues/2179), and **fixed upstream** in [`12df7fbd`](https://github.com/rspatial/terra/commit/12df7fbd4f85eb01faa02c580a31ce7e34275c6a).
  It was *not* covered by the #2175 fix, which moved `union()` onto `erase_agg()` -- the function `erase()` already called -- so it needed its own.
  `renv.lock` now pins that build, and the fix is **verified on this study area**: re-running the 42-tile benchmark that found the defect gives terra consistent on 42 of 42, where it managed 37 before, agreeing with sf to 0.000000 m².
  **Keep using `erase_polygons()` anyway.**
  It does two things the fix does not touch, neither of which is a terra bug: it returns `x` unchanged when `y` is empty (`sf::st_union()` of an empty layer is a zero-length geometry, and `st_difference()` against that fails with "replacement has 1 row, data has 0"), and it drops the non-polygonal residue an overlay leaves behind.
  That second one is the trap: a difference can come back as a bare `LINESTRING` sitting directly in the geometry column -- not inside a `GEOMETRYCOLLECTION` -- and `terra::vect()` then drops the geometry while keeping its attribute row, reproducing #2179's symptom from a different direction.
  One of tile 12's 6,871 differences was such a line, and it surfaced two calls later as `[as,sf] coercion failed`.
  `erase_polygons()` lives in `spatialutils` now, along with `overlay_left_join()` and `keep_polygons()`; it goes through `sf::st_difference()`, which cannot desynchronise because the attributes are columns of the same data frame as the geometry, at about twice terra's cost.
- **`sf::st_join()` is not an overlay.**
  It keeps whole geometries from `x` and emits one copy per `y` they touch.
  For assigning attributes by location, use an intersection so geometries are split at the boundary and each location carries exactly one set of values.
- **Areas must be planar.**
  `terra::expanse()` defaults to `transform = TRUE`, which reprojects to lon/lat and returns *geodesic* area.
  That is 2.8% larger than planar area in this project's Lambert CRS -- enough to move features across a 1 ha threshold and shift every reported total.
  Use `spatialutils::expanse_planar()`, or pass `transform = FALSE` explicitly.
- **Dissolving on columns that contain `NA`.**
  `terra::aggregate(by = )` returns a corrupt `SpatVector` when grouping on several columns and any of them has `NA` values -- its attribute table ends up with fewer rows than it has geometries, which errors on the next access rather than at the aggregate call.
  `tidyterra`'s `group_by()` / `summarise()` handle it correctly.
- **Prefer `tidyterra` verbs over raw terra accessors** for attribute work on a `SpatVector`: `filter()`, `mutate()`, `select()`, `group_by()`, `summarise()`, `pull()` all have methods, so the code reads the same as the `sf` + `dplyr` it replaced.
  Note `v[[name]]` returns a one-column
  *data.frame* (unlike `v$name`), which is an easy way to introduce a subtle bug.
- **`geotargets::tar_terra_vect()` has no `iteration` argument.**
  It swallows one via `...` and then fails at *store* time with `unused argument (iteration = "list")`, once per branch, after the work is done.
  Branched `tar_terra_vect()` targets already read back as a list, so just omit it.
- **Serialise vectors as GeoPackage.**
  `geotargets`' vector driver is pinned to `GPKG` in `_targets.R`.
  FlatGeobuf round-trips the same features in a *different order*, which would desynchronise the row-index chunking the distance calculations depend on.
- **An empty `SpatVector` from `terra::crop()` loses its attribute columns.**
  A no-overlap crop returns `nrow == 0` *and* zero columns, so a later `select()` fails with "column doesn't exist" rather than anything pointing at the crop.
  This is specific to `crop()`: `v[integer(0), ]`, `intersect()`, `erase()`, and `sf::st_crop()` all keep the columns when the result is empty.
  Nothing in terra's NEWS through dev 1.9-47 addresses it (checked against 1.8.86), so assume it is still present.
  Guard on `nrow() == 0` before touching attributes, and filter empty branches out before `rbind()`.
- **Exact quantiles over the distance dataset need a single sorted state.**
  `calc_all_dists_quantiles()` runs over 2.33 billion rows (18 GB of parquet), and an exact quantile cannot be streamed -- the column is materialised and sorted.
  Asking DuckDB for five quantiles as five separate aggregates gives it five sorted states at once: it peaked at 336 GB, drove a 1 TB machine to 3.6 GB available, and was OOM-killed six hours into a run.
  `quantile_cont(distance, [list of probs])` answers all of them from one sorted state -- 28.7 GB, 3.3 min, bit-identical values -- and a `memory_limit` makes DuckDB spill rather than die if it is squeezed.
  Do **not** reach for `approx_quantile()`: its t-digest error is around 1%, which on the ~43 km regional quantile is ~430 m, and the Omniscape radius changes every 90 m at 90 m resolution, so the approximation moves a pinned radius by several pixels.

- **Erasing several layers in sequence** is the same as erasing their union (`A \ B1 \ B2 = A \ (B1 ∪ B2)`), and much cheaper when the union is computed once.

## Package development

Helpers general enough to be useful elsewhere live in [`spatialutils`]( https://github.com/FOR-CAST/spatialutils); project-specific ones stay in `R/`.
If you find yourself writing a general-purpose spatial utility here, ask whether it should be promoted.

When working on a package:

- Use the `r-lib:r-package-development` skill.
- Make changes in a **local clone of that package's repository**, never in this project's `renv/library/`.
- **Never install a local copy.**
  Depend on the released/pushed version:
  ```r
  renv::install("FOR-CAST/spatialutils", lock = TRUE)
  ```
  `lock = TRUE` records the exact remote SHA in `renv.lock`, so a fresh clone of this project can actually install what it was tested against.
  Run it from **this** project's directory -- renv writes the lockfile of whatever project is active, so running it from the package's own clone drops a stray `renv.lock` there and installs into the wrong library.
- **`renv.lock` is deliberately kept in renv's v1 format** (compact records). renv 1.x writes v2 by default, which embeds each package's full DESCRIPTION and turns a one-package bump into a ~1,000-line diff.
  Preserve it when installing:
  ```r
  withr::with_options(list(renv.lockfile.version = 1), renv::install("FOR-CAST/spatialutils", lock = TRUE))
  ```
  (The `options(renv.lockfile.version = 1)` that used to sit in `.Rprofile` was there for `workflowtools` issue #1; that is obsolete -- `workflowtools::packages_from_snapshot()` reads both formats identically -- so the pin is now a readability choice, not a requirement.)
- Run `devtools::test()` and `devtools::check()` locally before pushing, and watch the package's GitHub Actions afterwards.
- Every user-facing change gets a `NEWS.md` bullet, and every fix gets a test that fails without it.
- **Use `usethis` for package plumbing** rather than editing files by hand -- `use_version()`, `use_package()`, `use_test()`, and friends.
  They do more than the one edit you were thinking of.

### Bumping the version

`usethis::use_version("dev")` is the way to do it, but it **refuses on a dirty tree** (`challenge_uncommitted_changes()`), and in a non-interactive session that is a hard stop rather than a prompt.
Two ways through, in order of preference:

1. Commit the substantive change first, then bump on the clean tree as its own commit -- this is the flow usethis expects.
2. Stash, bump, unstash.
   Workable, but the pop conflicts on `DESCRIPTION` (both the stash and the bump touch it) and can half-apply, leaving the rest of the work still in the stash.
   If that happens, recover with `git checkout stash@{0} -- <files>` rather than redoing the work.

If you bypass `use_version()` for any reason, **do everything it does**, not just the part you remembered:

| `use_version()` step | What it does |
| --- | --- |
| `proj_desc_field_update("Version", ...)` | bump `Version:` in `DESCRIPTION` |
| `use_news_heading(...)` | add a `NEWS.md` heading -- `# <pkg> (development version)` for a dev bump, `# <pkg> <version>` for a release |
| `use_c_version(...)` | update `src/version.c`, for packages that have one |
| `git_ask_commit(...)` | offer to commit `DESCRIPTION`, `NEWS.md`, `src/version.c` |

A bumped `DESCRIPTION` with no matching `NEWS.md` heading is the usual way this goes wrong: the bullets for the new version end up filed under the previous one.

## Git

- `origin` is `FOR-CAST/bc-connectivity`; `upstream` is `Heckford/bc-connectivity`.
  Work lands upstream by pull request.
- **Commits are GPG-signed and must be made by a human.**
  `pinentry` needs a TTY, which agent sessions do not have.
  Stage the changes and write the commit message to a file for the user to sign; do not work around it with `--no-gpg-sign`.
- Run `air format .` after generating R code (`air.toml` holds the settings).
- **One sentence per line in prose** (`.md`, `.Rmd`, `.qmd`).
  Semantic line breaks keep diffs to the sentences that actually changed, instead of reflowing a whole paragraph every time a word is added.
  This applies to prose only -- tables, code chunks, and YAML headers are left alone.
- Don't put hostnames, IP addresses, or other infrastructure details in tracked files.

## When results change

This pipeline produces numbers that end up in reports.
Any change that alters them -- not just bug fixes, but changes to thresholds, CRS handling, or area definitions -- needs to be stated plainly in the commit message and in the "Corrections" section of `README.md`, with the measured before/after.
Quantify the effect on the actual study area rather than describing it qualitatively; several past defects were only recognisable once someone put a hectare figure on them.
