## Install the pinned Julia environment for this project's Omniscape runs.
##
## Run it as:
##
##     julia +1.11.7 Omniscape/install.jl
##
## This used to be `using Pkg; Pkg.add("Omniscape")` into the *global* environment, which is not
## reproducible: the registered Omniscape 0.6.2 declares `Circuitscape = "5.13.1-5"`, so a bare
## `Pkg.add` resolves to the newest 5.x. Today that is 5.17.1, not the 5.15.0 this project's results
## were produced with, and Circuitscape 5.16/5.17 replaced the iterative solver -- it inflates the
## artifact-correction factors feeding flow_potential.tif and normalized_cum_currmap.tif, so the
## swap changes results without failing. `Project.toml` and `Manifest.toml` beside this file pin
## both packages exactly; this script installs from them and then checks what it got.

using Pkg

## Activate the environment beside this file, so the script behaves the same whether or not
## `--project=Omniscape` was passed on the command line.
Pkg.activate(@__DIR__)
Pkg.instantiate()

const REQUIRED = Dict(
    "Omniscape" => v"0.6.2",
    "Circuitscape" => v"5.15.0",
)

installed = Dict(
    pkg.name => pkg.version
    for pkg in values(Pkg.dependencies()) if haskey(REQUIRED, pkg.name)
)

wrong = [
    (name, get(installed, name, nothing), want)
    for (name, want) in REQUIRED
    if get(installed, name, nothing) != want
]

if !isempty(wrong)
    detail = join(
        ["  $name: got $(something(got, "nothing")), expected $want" for (name, got, want) in wrong],
        "\n",
    )
    error(
        "Pinned Omniscape environment did not resolve as expected:\n" * detail * "\n" *
        "Do not run the pipeline against this environment -- the results would not be comparable " *
        "to the published ones. See the Environment section of CLAUDE.md.",
    )
end

@info "Pinned Omniscape environment ready" julia = VERSION environment = @__DIR__
Pkg.status()
