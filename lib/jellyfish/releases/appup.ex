defmodule Jellyfish.Releases.Appup do
  @moduledoc """
  Generate appup files for hot upgrades

  Copied and/or modified from https://github.com/bitwalker/distillery/blob/master/lib/distillery/releases/appups.ex
  """

  @typedoc "An OTP application name."
  @type app :: atom

  @typedoc "A version string, such as `\"0.0.1\"`."
  @type version_str :: String.t()

  @typedoc "A filesystem path to a release or build artifact directory."
  @type path_str :: String.t()

  @typedoc "The purge mode used for a `:update` instruction."
  @type change :: :soft | {:advanced, [term]}

  @typedoc "Modules that must be loaded/updated before the module being instructed."
  @type dep_mods :: [module]

  @typedoc """
  An appup version, as expected by the `.appup` format: either a version
  string as a charlist, or a regular expression as a binary. The regex must
  match the entire version string for an application, or it is rejected.
  """
  @type appup_ver :: charlist | binary

  @typedoc "A single upgrade/downgrade instruction, as defined by the Erlang appup format."
  @type instruction ::
          {:add_module, module}
          | {:delete_module, module}
          | {:update, module, :supervisor | change}
          | {:update, module, change, dep_mods}
          | {:load_module, module}
          | {:load_module, module, dep_mods}
          | {:apply, {module, atom, [term]}}
          | {:add_application, atom}
          | {:remove_application, atom}
          | {:restart_application, atom}
          | :restart_new_emulator
          | :restart_emulator

  @typedoc "The instructions to run, per source version, when upgrading."
  @type upgrade_instructions :: [{appup_ver, instruction}]

  @typedoc "The instructions to run, per source version, when downgrading."
  @type downgrade_instructions :: [{appup_ver, instruction}]

  @typedoc "The contents of a generated `.appup` file: `{new_version, upgrades, downgrades}`."
  @type appup :: {appup_ver, upgrade_instructions, downgrade_instructions}

  @doc """
  Generate a .appup for the given application, start version, and upgrade version.

  ## Parameters

      - application: the application name as an atom
      - v1: the previous version, such as "0.0.1"
      - v2: the new version, such as "0.0.2"
      - v1_path: the path to the v1 artifacts (rel/<app>/lib/<app>-0.0.1)
      - v2_path: the path to the v2 artifacts (_build/prod/lib/<app>)

  """
  @spec make(app, version_str, version_str, path_str, path_str) :: {:ok, appup} | {:error, term}
  def make(application, v1, v2, v1_path, v2_path) do
    with {:ok, v1_props} <- consult_dotapp(application, v1_path),
         :ok <- check_vsn(:previous, vsn(v1_props), v1),
         {:ok, v2_props} <- consult_dotapp(application, v2_path),
         :ok <- check_vsn(:next, vsn(v2_props), v2) do
      {:ok, make_appup(application, v1, v1_path, v1_props, v2, v2_path, v2_props)}
    end
  end

  defp consult_dotapp(application, path) do
    dotapp =
      path
      |> Path.join("/ebin/")
      |> Path.join(Atom.to_string(application) <> ".app")
      |> String.to_charlist()

    case :file.consult(dotapp) do
      {:ok, [{:application, ^application, props}]} -> {:ok, props}
      {:error, reason} -> {:error, {:appups, :file, {:invalid_dotapp, reason}}}
    end
  end

  defp check_vsn(_which, vsn, vsn), do: :ok

  defp check_vsn(which, consulted_vsn, expected_vsn) do
    {:error,
     {:appups,
      {:mismatched_versions, [version: which, expected: expected_vsn, got: consulted_vsn]}}}
  end

  defp make_appup(_app, v1, v1_path, _v1_props, v2, v2_path, _v2_props) do
    v1 = String.to_charlist(v1)
    v2 = String.to_charlist(v2)
    v1_path = String.to_charlist(Path.join(v1_path, "ebin"))
    v2_path = String.to_charlist(Path.join(v2_path, "ebin"))

    {deleted, added, changed} = :beam_lib.cmp_dirs(v1_path, v2_path)

    actually_changed =
      changed
      |> Enum.filter(fn {v1_beam, v2_beam} ->
        case :beam_lib.cmp(v1_beam, v2_beam) do
          {:error, :beam_lib, {:chunks_different, ~c"Dbgi"}} ->
            # Due to the way Elixir generates core ast, all beams will always show as changed,
            # so we ignore this chunk in the comparison for changed beams
            false

          _ ->
            true
        end
      end)

    up_instructions =
      generate_instructions(:added, added)
      |> Enum.concat(generate_instructions(:changed, actually_changed))
      |> Enum.concat(generate_instructions(:deleted, deleted))

    down_instructions =
      generate_instructions(:deleted, added)
      |> Enum.concat(generate_instructions(:changed, actually_changed))
      |> Enum.concat(generate_instructions(:added, deleted))

    {
      # New version
      v2,
      # Upgrade instructions from version v1
      [{v1, up_instructions}],
      # Downgrade instructions to version v1
      [{v1, down_instructions}]
    }
  end

  # For modules which have changed, we must make sure
  # that they are loaded/updated in such an order that
  # modules they depend upon are loaded/updated first,
  # where possible (due to cyclic dependencies, this is
  # not always feasible). After generating the instructions,
  # we perform a best-effort topological sort of the modules
  # involved, such that an optimal ordering of the instructions
  # is generated
  defp generate_instructions(:changed, files) do
    files
    |> Enum.map(&generate_instruction(:changed, &1))
    |> topological_sort
  end

  defp generate_instructions(type, files) do
    Enum.map(files, &generate_instruction(type, &1))
  end

  defp generate_instruction(:added, file), do: {:add_module, module_name(file)}
  defp generate_instruction(:deleted, file), do: {:delete_module, module_name(file)}

  defp generate_instruction(:changed, {v1_file, v2_file}) do
    module_name = module_name(v1_file)
    attributes = beam_attributes(v1_file)
    exports = beam_exports(v1_file)
    imports = beam_imports(v2_file)
    is_supervisor = supervisor?(attributes)
    is_special_proc = special_process?(exports)

    depends_on =
      imports
      |> Enum.map(fn {m, _f, _a} -> m end)
      |> Enum.uniq()

    generate_instruction_advanced(module_name, is_supervisor, is_special_proc, depends_on)
  end

  defp beam_attributes(file) do
    {:ok, {_, [attributes: attributes]}} = :beam_lib.chunks(file, [:attributes])
    attributes
  end

  defp beam_imports(file) do
    {:ok, {_, [imports: imports]}} = :beam_lib.chunks(file, [:imports])
    imports
  end

  defp beam_exports(file) do
    {:ok, {_, [exports: exports]}} = :beam_lib.chunks(file, [:exports])
    exports
  end

  defp special_process?(exports) do
    Keyword.get(exports, :system_code_change) == 4 || Keyword.get(exports, :code_change) == 3 ||
      Keyword.get(exports, :code_change) == 4
  end

  defp supervisor?(attributes) do
    behaviours = Keyword.get(attributes, :behavior, []) ++ Keyword.get(attributes, :behaviour, [])
    :supervisor in behaviours || Supervisor in behaviours
  end

  # supervisor
  defp generate_instruction_advanced(m, true, _is_special, _dep_mods),
    do: {:update, m, :supervisor}

  # special process (i.e. exports code_change/3 or system_code_change/4)
  defp generate_instruction_advanced(m, _is_sup, true, []), do: {:update, m, {:advanced, []}}

  defp generate_instruction_advanced(m, _is_sup, true, dep_mods),
    do: {:update, m, {:advanced, []}, dep_mods}

  # non-special process (i.e. neither code_change/3 nor system_code_change/4 are exported)
  defp generate_instruction_advanced(m, _is_sup, false, []), do: {:load_module, m}
  defp generate_instruction_advanced(m, _is_sup, false, dep_mods), do: {:load_module, m, dep_mods}

  # This "topological" sort is not truly topological, since module dependencies
  # are represented as a directed, cyclic graph, and it is not actually
  # possible to sort such a graph due to the cycles which occur. However, one
  # can "break" loops, until one reaches a point that the graph becomes acyclic,
  # and those topologically sortable. That's effectively what happens here:
  # we perform the sort, breaking loops where they exist by attempting to
  # weight each of the two dependencies based on the number of outgoing dependencies
  # they have, where the fewer number of outgoing dependencies always comes first.
  # I have experimented with various different approaches, including algorithms for
  # feedback arc sets, and none appeared to work as well as the one below. I'm definitely
  # open to better algorithms, because I don't particularly like this one.
  defp topological_sort(instructions) do
    mods = Enum.map(instructions, fn i -> elem(i, 1) end)

    instructions
    |> Enum.sort(&do_sort_instructions(mods, &1, &2))
    |> Enum.map(fn
      {:update, _, _} = i ->
        i

      {:load_module, _} = i ->
        i

      {:update, m, type, deps} ->
        {:update, m, type,
         Enum.filter(deps, fn
           ^m -> false
           d -> d in mods
         end)}

      {:load_module, m, deps} ->
        {:load_module, m,
         Enum.filter(deps, fn
           ^m -> false
           d -> d in mods
         end)}
    end)
  end

  defp do_sort_instructions(mods, a, b) do
    am = elem(a, 1)
    bm = elem(b, 1)
    ad = extract_deps(a)
    bd = extract_deps(b)
    do_sort_instructions(mods, am, bm, ad, bd)
  end

  defp do_sort_instructions(mods, am, bm, ad, bd) do
    ad = filter_known_deps(ad, am, mods)
    bd = filter_known_deps(bd, bm, mods)

    compare_dependency_counts(am, bm, ad, bd)
  end

  defp filter_known_deps(deps, self_mod, mods) do
    Enum.filter(deps, fn
      ^self_mod -> false
      d -> d in mods
    end)
  end

  defp compare_dependency_counts(am, bm, ad, bd) do
    lad = length(ad)
    lbd = length(bd)

    cond do
      only_a_has_deps?(lad, lbd) ->
        true

      only_b_has_deps?(lad, lbd) ->
        false

      # If a depends on b and b doesn't depend on a
      # Then b comes first, and vice versa
      a_depends_on_b_only?(am, bm, ad, bd) ->
        true

      b_depends_on_a_only?(am, bm, ad, bd) ->
        false

      # If either they don't depend on each other,
      # or they both depend on each other, then the
      # module with the least outgoing dependencies
      # comes first. Otherwise we treat them as equal
      lad > lbd ->
        false

      lbd > lad ->
        true

      :else ->
        true
    end
  end

  defp only_a_has_deps?(0, lbd), do: lbd != 0
  defp only_a_has_deps?(_lad, _lbd), do: false

  defp only_b_has_deps?(lad, 0), do: lad != 0
  defp only_b_has_deps?(_lad, _lbd), do: false

  defp a_depends_on_b_only?(am, bm, ad, bd), do: am in bd and bm not in ad

  defp b_depends_on_a_only?(am, bm, ad, bd), do: am not in bd and bm in ad

  defp extract_deps({:update, _m, deps}) when is_list(deps), do: deps
  defp extract_deps({:update, _m, _change}), do: []
  defp extract_deps({:update, _m, _change, deps}), do: deps
  defp extract_deps({:update, _m, _change, _pre_purge, _post_purge, deps}), do: deps
  defp extract_deps({:load_module, _m, deps}), do: deps
  defp extract_deps({:load_module, _m, _pre_purge, _post_purge, deps}), do: deps
  defp extract_deps({:delete_module, _m, deps}), do: deps
  defp extract_deps({:add_module, _m, deps}), do: deps
  defp extract_deps(_), do: []

  defp module_name(file) do
    Keyword.fetch!(:beam_lib.info(file), :module)
  end

  defp vsn(props) do
    {:value, {:vsn, vsn}} = :lists.keysearch(:vsn, 1, props)
    List.to_string(vsn)
  end
end
