# Contributing

Thanks for your interest in this project. Contributions, bug reports, and questions are
welcome.

## Reporting problems

Please [open an issue](../../issues/new/choose). For bugs, include the output of
`sessionInfo()` (or the contents of [`INFO.md`](../INFO.md)), the `targets` target that
failed, and the full error message.

## Data access

Most input datasets download automatically from public catalogues (see
[Data sources](../README.md#data-sources) in the README). One layer -- the BC Cumulative
Effects Framework Forest Disturbance layer -- is a custom product that is not publicly
distributed and must be requested. See [Data access](../README.md#data-access) for details.

Please do not open issues requesting the restricted dataset itself; contact the data
steward named in the README.

## Making changes

1. Fork the repository and create a branch for your change.
2. Restore the project library with `renv::restore()` so you are working against the
   pinned package versions.
3. Make your change. R code is formatted with [air](https://posit-dev.github.io/air/);
   the project's settings are in [`air.toml`](../air.toml). If you use VS Code or
   Positron, format-on-save is already configured in `.vscode/settings.json`.
4. If you add or change a package dependency, update the lockfile with `renv::snapshot()`
   and commit `renv.lock`.
5. Open a pull request describing what changed and why.

## Scope

This repository implements a specific case study for the Quesnel Natural Resource
District. Changes that generalise the workflow to other study areas are welcome, but
please open an issue to discuss the approach before starting substantial work.

## Licence

By contributing, you agree that your contributions will be licensed under the
[Apache License 2.0](../LICENSE.md).
