defmodule Jellyfish.Integration.UmbrellaTest do
  use ExUnit.Case, async: false

  # Builds two releases of a real umbrella project with `mix release`, in a
  # separate Mix process, and checks the appups that end up in the release.
  #
  # The umbrella has two child apps:
  #
  #   app_one -> lib_direct -> lib_transitive
  #   app_two -> app_one (in_umbrella), lib_direct -> lib_transitive
  #
  # No child declares lib_transitive, and it is the only library that changes
  # version between the two releases.

  @moduletag :integration
  @moduletag timeout: 300_000

  @release_dir "_build/prod/rel/umb"

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "jellyfish-umbrella-#{System.unique_integer([:positive])}")

    File.rm_rf!(root)
    write_umbrella!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    first = release!(root, "0.1.0", "1.0.0")
    # A path dependency is not recompiled when only its version changes, and
    # neither are the umbrella apps (see "Generating Appup files" in the README)
    mix!(root, ["deps.compile", "lib_transitive", "--force"], "0.2.0", "1.1.0")
    mix!(root, ["compile", "--force"], "0.2.0", "1.1.0")
    second = release!(root, "0.2.0", "1.1.0")

    %{root: root, first: first, second: second}
  end

  test "checks a transitive dependency once, under the child app that brings it in", ctx do
    for output <- [ctx.first, ctx.second] do
      assert count(output, "[lib_direct]") == 1
      assert count(output, "[lib_transitive]") == 1
      assert count(output, "[app_one]") == 1
      assert count(output, "[app_two]") == 1
    end

    assert ctx.second =~ "appups: app_one/rel/appups/lib_transitive"
  end

  test "ships an appup for the transitive dependency that changed version", ctx do
    ebin = Path.join([ctx.root, @release_dir, "lib", "lib_transitive-1.1.0", "ebin"])

    assert {:ok, [{~c"1.1.0", [{~c"1.0.0", _up}], [{~c"1.0.0", _down}]}]} =
             ebin |> Path.join("lib_transitive.appup") |> String.to_charlist() |> :file.consult()

    assert %{
             "name" => "lib_transitive",
             "type" => "dependency",
             "from" => "1.0.0",
             "to" => "1.1.0"
           } = ebin |> Path.join("jellyfish.json") |> File.read!() |> Jason.decode!()
  end

  test "ships appups for the child apps and none for the dependency that did not change", ctx do
    lib = Path.join([ctx.root, @release_dir, "lib"])

    assert File.exists?(Path.join([lib, "app_one-0.2.0", "ebin", "app_one.appup"]))
    assert File.exists?(Path.join([lib, "app_two-0.2.0", "ebin", "app_two.appup"]))
    refute File.exists?(Path.join([lib, "lib_direct-1.0.0", "ebin", "lib_direct.appup"]))
  end

  test "the release can be turned into a relup", ctx do
    release_dir = Path.join(ctx.root, @release_dir)
    previous = String.to_charlist(Path.join(release_dir, "releases/umb-0.1.0"))
    current = String.to_charlist(Path.join(release_dir, "releases/umb-0.2.0"))
    options = [{:path, [String.to_charlist(Path.join(release_dir, "lib/*/ebin"))]}, :noexec]

    # :systools lives in :sasl, which is not on the code path of this project
    Mix.ensure_application!(:sasl)
    systools = :systools

    assert {:ok, {~c"0.2.0", [{~c"0.1.0", _description, up}], _down}, _module, _warnings} =
             systools.make_relup(current, [previous], [previous], [:silent | options])

    assert {:load_object_code, {:lib_transitive, ~c"1.1.0", [LibTransitive]}} in up
  end

  ### ==========================================================================
  ### Helpers
  ### ==========================================================================

  defp release!(root, version, lib_version), do: mix!(root, ["release"], version, lib_version)

  defp mix!(root, args, version, lib_version) do
    env = [
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_PATH", nil},
      {"MIX_DEPS_PATH", nil},
      {"JELLYFISH_PATH", File.cwd!()},
      {"UMBRELLA_VERSION", version},
      {"LIB_TRANSITIVE_VERSION", lib_version}
    ]

    {output, status} =
      System.cmd("mix", args, cd: root, env: env, stderr_to_stdout: true)

    assert status == 0, "mix #{Enum.join(args, " ")} failed:\n#{output}"
    output
  end

  defp count(output, text), do: output |> String.split(text) |> length() |> Kernel.-(1)

  defp write_umbrella!(root) do
    write!(root, "mix.exs", """
    defmodule Umb.MixProject do
      use Mix.Project

      def project do
        [
          apps_path: "apps",
          version: System.fetch_env!("UMBRELLA_VERSION"),
          deps: [{:jellyfish, path: System.fetch_env!("JELLYFISH_PATH")}],
          releases: [
            umb: [
              applications: [app_one: :permanent, app_two: :permanent],
              include_erts: false,
              steps: [:assemble, &Jellyfish.generate/1]
            ]
          ]
        ]
      end
    end
    """)

    write_app!(root, "apps/app_one", :app_one, ~s|System.fetch_env!("UMBRELLA_VERSION")|, """
    [{:lib_direct, path: "../../libs/lib_direct"}]
    """)

    write_app!(root, "apps/app_two", :app_two, ~s|System.fetch_env!("UMBRELLA_VERSION")|, """
    [{:app_one, in_umbrella: true}, {:lib_direct, path: "../../libs/lib_direct"}]
    """)

    write_app!(root, "libs/lib_direct", :lib_direct, ~s|"1.0.0"|, """
    [{:lib_transitive, path: "../lib_transitive"}]
    """)

    write_app!(
      root,
      "libs/lib_transitive",
      :lib_transitive,
      ~s|System.fetch_env!("LIB_TRANSITIVE_VERSION")|,
      "[]"
    )
  end

  defp write_app!(root, path, app, version, deps) do
    module = app |> Atom.to_string() |> Macro.camelize()
    umbrella? = String.starts_with?(path, "apps/")

    umbrella_paths =
      if umbrella? do
        """
        build_path: "../../_build",
              config_path: "../../config/config.exs",
              deps_path: "../../deps",
              lockfile: "../../mix.lock",
        """
      else
        ""
      end

    write!(root, Path.join(path, "mix.exs"), """
    defmodule #{module}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app},
          version: #{version},
          #{umbrella_paths}deps: #{String.trim(deps)}
        ]
      end
    end
    """)

    # The module returns its app version, so its beam changes with the version
    write!(root, Path.join(path, "lib/#{app}.ex"), """
    defmodule #{module} do
      def version, do: unquote(Mix.Project.config()[:version])
    end
    """)
  end

  defp write!(root, path, contents) do
    file = Path.join(root, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, contents)
  end
end
