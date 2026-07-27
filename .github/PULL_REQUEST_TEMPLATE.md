## Description

<!-- What does this change do, and why? Link any related issues. -->

## Type of change

- [ ] Bug fix
- [ ] New or changed analysis step
- [ ] Documentation
- [ ] Dependency / environment update

## Checklist

- [ ] Code is formatted with [air](https://posit-dev.github.io/air/) (`air format .`)
- [ ] `renv.lock` updated via `renv::snapshot()` if dependencies changed
- [ ] Affected `targets` targets rebuild successfully (`targets::tar_make(callr_function = NULL)`)
- [ ] `README.Rmd` updated and re-knit to `README.md` if documentation changed
- [ ] No credentials, absolute local paths, or restricted data committed
