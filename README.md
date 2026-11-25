<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/jellyfish-logo-dark.svg">
    <img src="assets/jellyfish-logo-light.svg" alt="Jellyfish logo" width="120">
  </picture>
</p>

# Jellyfish

> Simplifying Hot-Upgrades for Elixir Applications

[![Hex.pm Version](http://img.shields.io/hexpm/v/jellyfish.svg?style=flat)](https://hex.pm/packages/jellyfish)
[![CI](https://github.com/deployex/jellyfish/actions/workflows/pr-ci.yaml/badge.svg?branch=main)](https://github.com/deployex/jellyfish/actions/workflows/pr-ci.yaml)

Jellyfish is a library that generates appup files, enabling hot-upgrades for Elixir applications without downtime.

## What are Appup Files?
Appup files describe how to upgrade and downgrade an application from one version to another. They contain:

 * The application name
 * Instructions to upgrade to a newer version
 * Instructions to downgrade to the original version

For detailed information about the appup format, see the [Erlang appup manual](http://erlang.org/doc/man/appup.html).

## Important Upgrade Ordering
When upgrading processes, order matters:

 * Processes are suspended during upgrades
 * In-flight requests are handled by the old version until upgrade completes
 * Upgrade dependencies first, then dependents (e.g., if `proc_a` depends on `proc_b`, upgrade `proc_b` first)
 * Jellyfish automatically performs topological sorting when generating appups

### Purge semantics

Jellyfish emits `update`/`load_module` instructions without an explicit purge mode, so OTP's release handler falls back to `brutal_purge` for both the pre-purge and post-purge steps.
With `brutal_purge`, any process still executing old code when the purge runs is killed outright, rather than being given a chance to finish.
This is the same default every appup-generation tool in this family uses, and matches what `systools:make_relup` itself defaults to when no purge mode is given.
If a specific module needs the safer `soft_purge` behavior (the purge is deferred, and `release_handler:install_release/1` returns `{error, {old_processes, Mod}}` instead of killing anything), edit the generated `.appup` by hand, or use the `EDIT_APPUP` flow described below, before packaging the release.

## Installation

Add `jellyfish` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:jellyfish, "~> 0.2.0"}
  ]
end
```

## Basic Configuration
Add the following lines in the `mix.exs` project:

```elixir
  def project do
    [
      ...
      releases: [
        your_app_name: [
          steps: [:assemble, &Jellyfish.generate/1, :tar]
        ]
      ],
      ...
    ]
  end
```

Once the `mix release` is called, if a previous version is found, the appup file will be automatically generated and included in the release package for executing hot-upgrades.

### Hot-Upgrading Dependencies (Optional)

Jellyfish generates appup files for both your application code and its dependencies. This allows you to upgrade third-party libraries at runtime alongside your own code changes.

This covers the production dependencies declared in your `mix.exs` and the dependencies that they bring in, as long as the release ships them.
For example, if you declare `finch` and an update moves `nimble_pool`, which `finch` depends on, `nimble_pool` gets its own appup without being declared.
`systools:make_relup/4` needs an appup for every application whose version changes, so a release that moves a transitive dependency can still be hot-upgraded.
A dependency that you declare with `runtime: false` or for `:dev`/`:test` only is skipped, even when another dependency brings it in.

> [!WARNING]
> Not all code changes are safe for hot-upgrades.
> Before performing a hot-upgrade, check if the dependency supports hot-upgrades between versions, review the changelog for structural changes (e.g., process state modifications, API changes), and check stateful processes like GenServers, Agents, etc. that may require special handling.
> You can do this analysis yourself, or ask an LLM-based coding assistant to review the diff and changelog between the two versions and flag anything that looks unsafe for a hot-upgrade - but either way, someone should look before you ship it.

### Which previous version is used

An appup upgrades from one previous version, the highest one found in the release directory that an earlier build left on disk, other than the version being built.
"Highest" is decided this way, and [rebar3_jellyfish_plugin](https://github.com/deployex/rebar3_jellyfish_plugin) follows the same order:

 * Versions are compared as [Semantic Versioning](https://semver.org/#spec-item-11) says: `0.10.0` is higher than `0.9.0`, and a pre-release is lower than its release, `1.0.0-rc1` below `1.0.0`.
 * Build metadata, `1.0.0+abc`, is ignored.
 * A `git describe` version, `1.0.0-4-gabc1234`, is higher than `1.0.0`, and more commits is higher.
 * A version that is not `MAJOR.MINOR.PATCH` is not ordered in a useful way, use one that is.

> [!NOTE]
> A build identifier after the version, such as `0.1.0-9cad9cd`, is ordered as text.
> Two builds of the same version are therefore not ordered by when they were built.
> When versions are named this way, keep a single previous version in the release directory: build the version that is deployed, then the new one.

# Appup file

Jellyfish writes an appup from what changed in the compiled modules.
It cannot see what a release changes around them: a process that exists in one version and not in the other, a supervisor whose `init/1` cannot run twice, a different shape of the data that processes share.
An upgrade like that needs other instructions, and there are three ways to give them.

## An override in the repository

Write the appup by hand, and keep it where Jellyfish looks for one:

```
rel/appup_overrides/<application>/<from>_to_<to>.appup
```

When the release is built for exactly that upgrade of that application, the file is used as it is, comments included, and nothing is generated for it.

```erlang
%% rel/appup_overrides/finch/0.24.0_to_0.25.0.appup
%%
%% Finch 0.25 starts a process that 0.24 did not have, and its supervisor creates a named
%% table when it starts, so it cannot be updated in place. Every instance is stopped
%% through its supervisor, the code is loaded, and the instances are started again.
{"0.25.0",
 [{"0.24.0",
   [{stop, ['Elixir.Finch']},
    {load_module, 'Elixir.Finch'},
    {load_module, 'Elixir.Finch.Pool.Manager'},
    {start, ['Elixir.Finch']}]}],
 [{"0.24.0",
   [{stop, ['Elixir.Finch']},
    {load_module, 'Elixir.Finch'},
    {load_module, 'Elixir.Finch.Pool.Manager'},
    {start, ['Elixir.Finch']}]}]}.
```

 * **It is reviewed as code is.** The file is committed, so the instructions and the reasons for them go through a pull request, and a pipeline builds the same release every time. Start from the appup Jellyfish generated, in `rel/appups/<application>/`.
 * **It only applies to the upgrade its name says.** Any other pair of versions ignores it, so it can stay in the repository after it has served.
 * **It works for a dependency as for your own application**, which is where it is needed most: the dependency is not yours to change.
 * **A file that is not usable fails the build.** One that cannot be read, or that holds an appup for other versions than its name says, is an error, and not a silent return to the generated appup that the override was written to avoid.
 * **In an umbrella project**, the directory is looked for in the child application that is being compiled, and then in the root of the umbrella.

The build says which appups came from an override:

```
[finch]    versions: ["0.24.0", "0.25.0"]    current: 0.25.0    - appups: my_app/rel/appups/finch, from the override rel/appup_overrides/finch/0.24.0_to_0.25.0.appup
```

## Editing during the build

Set the __EDIT_APPUP__ environment variable, and Jellyfish waits for you to edit each generated file before it goes in the release:

```bash
EDIT_APPUP=true MIX_ENV=prod mix release
```

It suits a release built by hand. A pipeline cannot answer it, and the edit is not kept anywhere.

## Editing the release

Untar the release, change the appup files and tar it again.

## Known Limitations

Jellyfish reads compiled modules, so what a release changes outside of them is not in the appup it generates.

### Supervisor child changes

When a supervisor module changes, Jellyfish always emits the generic `{update, Module, supervisor}` instruction.
This instruction lets the release handler pick up changes to an existing child's spec, such as its start function or restart type, but only once that child restarts for some other reason: a running child keeps its old spec until then.
Per the [Erlang appup cookbook](https://www.erlang.org/doc/system/appup_cookbook.html), a new child specification is added automatically, but the matching child process is not started, and a removed child's process is not stopped.
So if a release adds or removes a supervisor's child, the generated appup alone will not start or stop that process.
The upgrade will look successful while leaving a new worker not started, or a removed one still running.
Use `EDIT_APPUP` to add the missing `{apply, {supervisor, start_child, [...]}}`, `{apply, {supervisor, terminate_child, [...]}}`, or `{apply, {supervisor, delete_child, [...]}}` instructions by hand whenever a release changes a supervisor's children, not just its properties.

### NIFs and non-OTP processes

The purge mode described in [Purge semantics](#purge-semantics) is safe for a `GenServer`, a `:gen_statem` or a supervisor, since the standard upgrade protocol suspends and resumes those processes around the code swap, so none of them is still running old code by the time the purge happens.
It is not safe for a process that does not go through that protocol, such as a plain `spawn_link` loop, a `Task` that runs for a long time, or a process blocked inside a NIF call: it can still be executing old code when the purge runs, and is killed.
If a release touches a NIF-loaded module or a hand-rolled, non-OTP process, review whether `brutal_purge` is appropriate before shipping the upgrade, and use `EDIT_APPUP` to switch the relevant instruction to `soft_purge` if it is not.

# Relup file

The library focuses on generating appup files and includes them in the mix release package. It doesn't create relup files directly. The relup file is typically created during a hot upgrade with the [DeployEx](https://github.com/deployex/deployex) application.

# The jellyfish.json file

Alongside every `.appup` file, Jellyfish writes a `jellyfish.json` file into the same `ebin` directory.
This is the signal a tool like DeployEx should check before trusting an `.appup` file, rather than the mere presence of the `.appup` itself.
A dependency can legitimately ship its own `.appup` file for unrelated reasons, and treating that as a hot-upgrade instruction would be a mistake.
`jellyfish.json` only exists when Jellyfish itself generated and validated the appup, so its presence next to the `.appup` is the actual contract.

It contains:

```json
{
  "name": "my_app",
  "type": "project",
  "from": "0.1.0",
  "to": "0.1.1",
  "format_version": 1,
  "generator": "jellyfish/0.2.7"
}
```

 * `name`: the OTP application the appup belongs to.
 * `type`: `project` for the release's own application, `dependency` for one of its production dependencies.
 * `from` / `to`: the versions the appup upgrades between.
 * `format_version`: the schema version of this file. Bumped whenever a field is added, renamed, or removed. Readers (such as DeployEx) should branch on this rather than assuming the current shape.
 * `generator`: which tool and version produced the file, for provenance/debugging.

This is a stable, tool-agnostic contract: any generator that produces an appup the same way, including [rebar3_jellyfish_plugin](https://github.com/deployex/rebar3_jellyfish_plugin) for Erlang/rebar3 releases, writes the same file shape so a reader never has to know whether a release came from `mix` or `rebar3`.

# Elixir Umbrella applications

The next sections describe how to set up and use Jellyfish with Elixir umbrella applications for hot code upgrades.

## Versioning

Elixir umbrella applications contain multiple apps, each with its own `mix.exs` file and version. However, Jellyfish expects a single consistent version for the entire umbrella application. To ensure version consistency across all apps, we recommend two approaches:"

### Versioning using a shared mix config

Create a new file `mix/shared.exs` at the root of your umbrella project and add the following code:
```Elixir
defmodule Mix.Shared do
  def version, do: "0.1.0"
end
```

Add the load of this file in the root Mix File Setup:
```Elixir
Code.require_file("mix/shared.exs")

defmodule Myumbrella.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: Mix.Shared.version(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        myumbrella: [
          applications: [
            app_1: :permanent,
            app_2: :permanent,
            app_web: :permanent
          ],
          steps: [:assemble, &Jellyfish.generate/1, :tar]
        ]
      ]
      ...
    ]
  end

  defp deps do
    [
      {:jellyfish, "~> 0.2.0"}
    ]
  end
end
```

Each application within the umbrella should reference the same version file:

> #### Child App Mix File Setup
>
> Jellyfish dependency is not required for the child apps

```Elixir
defmodule App1.MixProject do
  use Mix.Project

  def project do
    [
      app: :app_1,
      version: Mix.Shared.version(),
      # Other configuration...
    ]
  end
  # Rest of the mix file...
end
```

### Versioning using a text file
Create a new file `version.txt` at the root of your umbrella project.

Root Mix File Setup:
```Elixir
defmodule Myumbrella.MixProject do
  use Mix.Project

  @version File.read!("version.txt")

  def project do
    [
      apps_path: "apps",
      version: @version,
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        myumbrella: [
          applications: [
            app_1: :permanent,
            app_2: :permanent,
            app_web: :permanent
          ],
          steps: [:assemble, &Jellyfish.generate/1, :tar]
        ]
      ]
    ]
  end

  defp deps do
    [
      {:jellyfish, "~> 0.2.0"}
    ]
  end
end
```

Each application within the umbrella should reference the same version file:

> #### Child App Mix File Setup
>
> Jellyfish dependency is not required for the child apps

```Elixir
defmodule App1.MixProject do
  use Mix.Project

  @version File.read!("../../version.txt")

  def project do
    [
      app: :app_1,
      version: @version,
      # Other configuration...
    ]
  end
  # Rest of the mix file...
end
```

## Dependencies

Each child app is checked with its own dependencies, the ones it declares and the ones those bring in, so a library that no child app declares still gets its appup.
A dependency that several child apps share is checked once, and its appup is written under the first child app that brings it in (for example `apps/app_1/rel/appups/<dependency>`).
Dependencies declared only in the root `mix.exs` are not checked, declare a dependency in the child app that uses it.

## Generating Appup files

When building releases for hot code upgrades in umbrella applications, modifying the version file does not trigger the compiler to detect changes in mix.exs across all apps. In this scenario, all apps need to be recompiled to make the new version available to the compiler's tasks, which would normally require forcing compilation.

1. Build the initial release:
```bash
# Release the version 0.1.0
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
```

2. Update the version (e.g., from `0.1.0` to `0.1.1`) in `version.txt`
3. Build the new release with forced compilation:
```bash
MIX_ENV=prod mix deps.get # optional, in case you had updated any dependency
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix compile --force
MIX_ENV=prod mix release
```

## Examples
Explore these resources for practical examples of using Jellyfish with Elixir applications:

 * [Deployex](https://github.com/deployex/deployex) - Elixir application showcasing Jellyfish's capabilities in deployment with hot-upgrades.
 * [Calori](https://github.com/thiagoesteves/calori) - Elixir application using Jellyfish and being able to hot upgrade via DeployEx
 * [Myumbrella](https://github.com/thiagoesteves/myumbrella) - Elixir umbrella application configured for using Jellyfish.

## Getting involved

🗨️ **Contact us:**
Feel free to contact me on [Linkedin](https://www.linkedin.com/in/thiago-cesar-calori-esteves-972368115/).

## Copyright and License

Copyright (c) 2024, Thiago Esteves.

Jellyfish source code is licensed under the [MIT License](LICENSE.md).

# References

 * Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/jellyfish>.
References:
 * [Distillery](https://github.com/bitwalker/distillery)
 * [Forecastle](https://github.com/ausimian/forecastle)
 * [Relx](https://github.com/erlware/relx/blob/main/priv/templates/install_upgrade_escript)