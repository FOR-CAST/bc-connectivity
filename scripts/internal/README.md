# Internal project-team scripts

The scripts in this directory are **not part of the reproducible analysis workflow** and
will not work outside the original project team.

They automate transferring data and results between a local working copy and the private
Microsoft Teams / SharePoint site used by the project team during Phases 1-3:

- `download_msteams.R` -- download shared input data from the Teams channel;
- `upload_msteams.R` -- upload processed rasters and Omniscape outputs back to SharePoint.

Both require membership in the private `bcgov` Microsoft 365 tenant and access to the
*External: Landscape Integrity* team. They authenticate interactively via the
[`Microsoft365R`](https://github.com/Azure/Microsoft365R) package using Microsoft's public
Azure CLI client ID -- no credentials are stored in this repository.

They are retained for provenance, to document how the project's shared data were staged.
**If you are reproducing this analysis, you do not need these scripts.** See the
[Data access](../../README.md#data-access) section of the main README for how to obtain
the input datasets.
