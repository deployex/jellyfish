defmodule Jellyfish.Releases.Override do
  @moduledoc """
  An appup written by hand, that the release uses in place of the generated one.

  Jellyfish writes an appup from what changed in the compiled modules. It cannot see what a
  release changes around them: a process that exists in one version and not in the other,
  a supervisor whose `init/1` cannot run twice, a different shape of the data that
  processes share. An upgrade like that needs other instructions, usually to stop the
  processes, load the code and start them again, and somebody has to write them.

  An override is where they go. It is a file in the repository, reviewed as code is:

      rel/appup_overrides/<application>/<from>_to_<to>.appup

  for example `rel/appup_overrides/finch/0.24.0_to_0.25.0.appup`. When the release is built
  for exactly that upgrade of that application, the file is used as it is, comments
  included, and nothing is generated for it. Any other upgrade ignores it, so an override
  can stay in the repository after it has served.

  In an umbrella project, the directory is looked for in the child application that is
  being compiled and then in the root of the umbrella.

  The file holds one appup term, for the two versions its name says:

      %% Why the generated instructions do not work, and what these do instead.
      {"0.25.0",
       [{"0.24.0", [{stop, ['Elixir.Finch']}, {load_module, 'Elixir.Finch'}, {start, ['Elixir.Finch']}]}],
       [{"0.24.0", [{stop, ['Elixir.Finch']}, {load_module, 'Elixir.Finch'}, {start, ['Elixir.Finch']}]}]}.

  A file that cannot be read, or that is for other versions than its name says, fails the
  build: a release that silently fell back to the generated appup would be the one the
  override was written to avoid.
  """

  @dir Path.join("rel", "appup_overrides")

  @doc """
  The directory overrides are kept in, relative to the project.
  """
  @spec dir() :: String.t()
  def dir, do: @dir

  @doc """
  Looks for the override of the upgrade of `app` from `v1` to `v2`.

  Returns the path of the file when there is one and it holds an appup for those versions,
  `:none` when there is no file, and an error when the file is not usable.
  """
  @spec find(atom(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | :none | {:error, term()}
  def find(app, v1, v2, roots \\ roots()) do
    roots
    |> Enum.map(&Path.join([&1, @dir, "#{app}", "#{v1}_to_#{v2}.appup"]))
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> :none
      path -> validate(path, v1, v2)
    end
  end

  ### ==========================================================================
  ### Private functions
  ### ==========================================================================

  # The project being compiled, and the root of the umbrella it is a child of
  defp roots do
    root =
      case Mix.Project.config()[:lockfile] do
        lockfile when is_binary(lockfile) -> lockfile |> Path.expand() |> Path.dirname()
        _no_lockfile -> File.cwd!()
      end

    Enum.uniq([File.cwd!(), root])
  end

  defp validate(path, v1, v2) do
    from = String.to_charlist(v1)
    to = String.to_charlist(v2)

    case :file.consult(String.to_charlist(path)) do
      {:ok, [{^to, [{^from, up}], [{^from, down}]}]} when is_list(up) and is_list(down) ->
        {:ok, path}

      # One upgrade and one downgrade, both for the version of its name, are what is expected
      {:ok, [{other_to, up, down}]} when is_list(up) and is_list(down) ->
        got = [to: version(other_to), upgrade_from: versions(up), downgrade_to: versions(down)]
        expected = [to: v2, upgrade_from: [v1], downgrade_to: [v1]]

        {:error,
         {:appups,
          {:invalid_override, path, {:mismatched_versions, [expected: expected, got: got]}}}}

      {:ok, _terms} ->
        {:error, {:appups, {:invalid_override, path, :not_an_appup}}}

      {:error, reason} ->
        {:error, {:appups, {:invalid_override, path, reason}}}
    end
  end

  defp versions(entries), do: Enum.map(entries, &version/1)

  defp version({version, _instructions}), do: version(version)
  defp version(version) when is_list(version), do: List.to_string(version)
  defp version(other), do: other
end
