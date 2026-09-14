# Internal project-team scripts

The scripts in this directory are **not part of the reproducible analysis workflow** and
will not work outside the original project team.

They automate transferring data and results between a local working copy and the private
Microsoft Teams / SharePoint site used by the project team during Phases 1-3:

- `download_msteams.R` -- download shared input data from the Teams channel;
- `upload_msteams.R` -- upload processed rasters and Omniscape outputs back to SharePoint.

`upload_msteams.R` is **read-only by default** (`DRY_RUN <- TRUE`).
It compares the local results against what is already on the site and prints the files that are
missing or have changed, which is what you need in front of you when transferring by hand.

Uploading from R needs a Graph token carrying `Files.ReadWrite.All` or `Sites.ReadWrite.All`.
The public Azure CLI client this script authenticates with is not consented for either in the
`bcgov` tenant, so reads succeed and the first `upload_file()` returns HTTP 401.
Transfers are therefore done in the browser.
Setting `DRY_RUN <- FALSE` without a write scope stops with that explanation rather than failing
partway through a large file.

It takes its local paths from the pipeline's own `get_path()`, so it follows the project layout
rather than restating it.
It considers only the Omniscape runs that are results, not the thread-scaling benchmark reruns, and
it treats a run that has been moved into `_old/` on the site as archived rather than as something
still to upload.

Both require membership in the private `bcgov` Microsoft 365 tenant and access to the
*External: Landscape Integrity* team. They authenticate interactively via the
[`Microsoft365R`](https://github.com/Azure/Microsoft365R) package using Microsoft's public
Azure CLI client ID -- no credentials are stored in this repository.

They are retained for provenance, to document how the project's shared data were staged.
**If you are reproducing this analysis, you do not need these scripts.** See the
[Data access](../../README.md#data-access) section of the main README for how to obtain
the input datasets.
