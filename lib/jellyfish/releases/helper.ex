defmodule Jellyfish.Releases.Helper do
  @moduledoc """
  Helper functions for managing dependencies in release builds.

  This module provides utilities to filter and identify production dependencies
  from a Mix project's dependency list, which is useful when creating releases
  or analyzing which dependencies will be included in production environments.
  """

  ### ==========================================================================
  ### Public APIs
  ### ==========================================================================

  @doc """
  Filters a list of dependencies to return only those that should be included in production.

  This function analyzes dependency specifications and their options to determine
  which dependencies are actually needed in a production release. It considers
  various dependency options such as `:runtime`, `:only`, `:in_umbrella`, `:compile`,
  and `:app` to make this determination.

  For more information about Mix dependencies, see:
  https://hexdocs.pm/mix/Mix.Tasks.Deps.html
  """
  @spec prod_dependencies(list()) :: list(atom())
  def prod_dependencies(deps) do
    Enum.reduce(deps, [], fn
      {lib, requirement}, acc when is_binary(requirement) ->
        acc ++ [lib]

      {lib, options}, acc ->
        if dependency_in_prod?(options) do
          acc ++ [lib]
        else
          acc
        end

      {lib, _requirement, options}, acc ->
        if dependency_in_prod?(options) do
          acc ++ [lib]
        else
          acc
        end
    end)
  end

  @doc """
  Returns the production dependencies of a project, including the transitive ones.

  It starts from the dependencies that `prod_dependencies/1` selects from `deps` and
  follows `deps_tree` (as returned by `Mix.Project.deps_tree/0`) to add the dependencies
  that they bring in, so a library the project does not declare itself is still found.
  The declared dependencies come first, in their declared order.

  A transitive dependency is left out when:

    * the project declares it and `prod_dependencies/1` rejects that declaration
      (for example `runtime: false` or `only: :dev`);
    * it is not in `deps_tree`, such as an optional dependency that was not fetched;
    * `release_apps` is a list and the dependency is not in it. Pass the applications
      of the release here to skip dependencies that the release does not ship.

  ## Examples

      iex> deps = [{:finch, "~> 0.20"}, {:credo, "~> 1.7", only: :dev}]
      iex> tree = %{finch: [:mint, :nimble_pool], mint: [], nimble_pool: [], credo: [:bunt]}
      iex> Jellyfish.Releases.Helper.prod_dependencies(deps, tree)
      [:finch, :mint, :nimble_pool]
      iex> Jellyfish.Releases.Helper.prod_dependencies(deps, tree, [:finch, :mint])
      [:finch, :mint]

  """
  @spec prod_dependencies(list(), %{optional(atom()) => [atom()]}, [atom()] | nil) ::
          list(atom())
  def prod_dependencies(deps, deps_tree, release_apps \\ nil) do
    direct = prod_dependencies(deps)
    rejected = Enum.map(deps, &elem(&1, 0)) -- direct

    allowed? = fn app ->
      Map.has_key?(deps_tree, app) and app not in rejected and
        (is_nil(release_apps) or app in release_apps)
    end

    direct ++ transitive_dependencies(direct, deps_tree, allowed?, direct)
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # Breadth-first walk of the dependency tree. `seen` also guards against cycles.
  defp transitive_dependencies([], _deps_tree, _allowed?, _seen), do: []

  defp transitive_dependencies(apps, deps_tree, allowed?, seen) do
    found =
      apps
      |> Enum.flat_map(&Map.get(deps_tree, &1, []))
      |> Enum.uniq()
      |> Enum.filter(&(&1 not in seen and allowed?.(&1)))

    found ++ transitive_dependencies(found, deps_tree, allowed?, seen ++ found)
  end

  defp dependency_in_prod?(options) do
    runtime? = Keyword.get(options, :runtime, true)

    prod? =
      case Keyword.get(options, :only) do
        env when is_list(env) ->
          :prod in env

        env when env in [:dev, :test] ->
          false

        _ ->
          true
      end

    in_umbrella? = Keyword.get(options, :in_umbrella, false)
    compile? = Keyword.get(options, :compile, true)
    app? = Keyword.get(options, :app, true)

    runtime? and prod? and app? and compile? and not in_umbrella?
  end
end
