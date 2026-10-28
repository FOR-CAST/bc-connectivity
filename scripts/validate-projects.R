#!/usr/bin/env Rscript

## Validate every `targets` project in `_targets.yaml`, without running a target.
##
## Two checks:
##
## 1. The pipeline definition BUILDS. `tar_manifest()` constructs the whole thing, so it catches
##    what `tar_validate()` catches -- a factory that errors for one district but not another, a
##    literate document a `tar_render()` target cannot parse.
##
## 2. Every symbol a command references RESOLVES. `targets` does NOT check this, and the gap is not
##    hypothetical: `omniscape_summary` called `zonal_summaries(omniscape_run, study_area, LCC, ...)`
##    naming ten targets that exist only in the PREP project, and it went unnoticed from 8e88b9a
##    until a district first completed an Omniscape run. Nothing caught it because the function
##    returns early when no runs exist and R's lazy evaluation never forced the arguments, so the
##    target reported as built. `connectivity_categories` failed the same way for the same reason.
##
## Run it after touching `_targets*.R`, anything in `R/`, or `_targets.yaml`:
##
##     Rscript-4.5.3 scripts/validate-projects.R

targets::tar_source()

## Symbols a command actually depends on.
##
## `all.vars()` is not usable here: for `district$key` it returns both `district` AND `key`, and
## `key` is a field name, not a variable, so every such command would report a phantom. Walk the
## call tree instead.
##
## `$` and `@` take the left operand only, for that reason. `::` and `:::` contribute NOTHING --
## both operands are names, the package and the export, and neither is a variable in scope.
command_symbols <- function(expr) {
  found <- character()

  walk <- function(e) {
    if (is.symbol(e)) {
      name <- as.character(e)
      if (nzchar(name)) {
        found <<- c(found, name)
      }
      return(invisible(NULL))
    }

    if (!is.call(e)) {
      return(invisible(NULL))
    }

    head <- e[[1]]

    if (is.symbol(head) && as.character(head) %in% c("::", ":::")) {
      return(invisible(NULL))
    }

    if (is.symbol(head) && as.character(head) %in% c("$", "@")) {
      walk(e[[2]])
      return(invisible(NULL))
    }

    for (i in seq_along(e)) {
      arg <- e[[i]]
      if (!missing(arg) && !identical(arg, quote(expr = ))) {
        walk(arg)
      }
    }

    invisible(NULL)
  }

  walk(expr)
  unique(found)
}

## Names the project's own `_targets*.R` binds at top level -- `OMNISCAPE_VINTAGE`, `n_tiles` and
## the like. They are in scope when the pipeline is defined but are not targets and are not in `R/`,
## so without this every command using one would be reported.
script_bindings <- function(path) {
  assigned <- vapply(
    as.list(parse(path)),
    function(e) {
      if (is.call(e) && length(e) >= 3L && is.symbol(e[[1L]])) {
        if (as.character(e[[1L]]) %in% c("<-", "<<-", "=") && is.symbol(e[[2L]])) {
          return(as.character(e[[2L]]))
        }
      }
      NA_character_
    },
    character(1)
  )

  unique(assigned[!is.na(assigned)])
}

projects <- setdiff(names(yaml::read_yaml("_targets.yaml")), "main")

results <- list()
failed <- FALSE

for (project in projects) {
  Sys.setenv(TAR_PROJECT = project)

  manifest <- tryCatch(
    targets::tar_manifest(fields = tidyselect::all_of(c("name", "command"))),
    error = function(e) e
  )

  if (inherits(manifest, "error")) {
    cat(sprintf(
      "FAIL %-34s pipeline definition errored: %s\n",
      project,
      conditionMessage(manifest)
    ))
    failed <- TRUE
    next
  }

  defined <- manifest$name
  in_scope <- c(defined, script_bindings(targets::tar_config_get("script")))
  unresolved <- list()

  for (i in seq_len(nrow(manifest))) {
    syms <- command_symbols(str2lang(paste(manifest$command[[i]], collapse = "\n")))
    ## A symbol is fine if it is another target here, something the project script bound, something
    ## `tar_source()` defined, or anything else reachable on the search path.
    missing_syms <- syms[!syms %in% in_scope & !vapply(syms, exists, logical(1))]

    if (length(missing_syms)) {
      unresolved[[manifest$name[[i]]]] <- missing_syms
    }
  }

  results[[project]] <- length(defined)

  if (length(unresolved)) {
    failed <- TRUE
    cat(sprintf("FAIL %-34s %d targets, unresolved symbols:\n", project, length(defined)))
    for (target in names(unresolved)) {
      cat(sprintf("       %-28s %s\n", target, paste(unresolved[[target]], collapse = ", ")))
    }
  } else {
    cat(sprintf("ok   %-34s %d targets\n", project, length(defined)))
  }
}

## The factories generate every district from one definition, so two projects of the same kind
## disagreeing on target count means a change reached one and not the others.
kinds <- sub("^_targets_([a-z]+)_.*$", "\\1", names(results))

for (kind in unique(kinds)) {
  counts <- unlist(results[kinds == kind])

  if (length(unique(counts)) > 1L) {
    failed <- TRUE
    cat(sprintf(
      "FAIL %s projects disagree on target count: %s\n",
      kind,
      paste(sprintf("%s=%d", names(counts), counts), collapse = ", ")
    ))
  }
}

if (failed) {
  quit(status = 1L)
}

cat("\nall projects valid\n")
