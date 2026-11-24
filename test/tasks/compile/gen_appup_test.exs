defmodule Mix.Tasks.Compile.GenAppupTest.FixtureProject do
  @moduledoc false

  # Reuses the real project config but swaps in a fake production
  # dependency, so GenAppup's dependency-generation loop (normally
  # empty, since this project has no runtime deps of its own) can be
  # exercised.
  def project, do: Jellyfish.MixProject.project() |> Keyword.put(:deps, [{:fakeapp, ">= 0.0.0"}])
end

defmodule Mix.Tasks.Compile.GenAppupTest.TransitiveFixtureProject do
  @moduledoc false

  # Declares one of this project's own dependencies as a production
  # dependency. mix_audit brings in jason and yaml_elixir, and yaml_elixir
  # brings in yamerl, none of which the fixture declares.
  def project do
    Jellyfish.MixProject.project() |> Keyword.put(:deps, [{:mix_audit, "~> 2.1"}])
  end
end

defmodule Mix.Tasks.Compile.GenAppupTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Compile.GenAppup

  @app_name Mix.Project.config()[:app]
  @output_dir "_build/#{Mix.env()}/rel/#{@app_name}"

  setup do
    File.rm_rf!(@output_dir)

    on_exit(fn ->
      File.rm_rf!("rel")
      File.rm_rf!(@output_dir)
    end)

    :ok
  end

  # Seeds a fake previous release under @output_dir/lib/<app>-<version>/ebin
  # by copying the currently compiled app and rewriting its declared
  # version, giving Appup.make a real (if diff-free) pair of .app/.beam
  # trees to compare against.
  defp seed_previous_release(version) do
    current_ebin = Path.join(Application.app_dir(@app_name), "ebin")
    previous_ebin = Path.join([@output_dir, "lib", "#{@app_name}-#{version}", "ebin"])
    File.mkdir_p!(previous_ebin)

    for entry <- File.ls!(current_ebin) do
      File.cp!(Path.join(current_ebin, entry), Path.join(previous_ebin, entry))
    end

    {:ok, [{:application, app, meta}]} =
      Path.join(previous_ebin, "#{@app_name}.app") |> :file.consult()

    previous_meta = Keyword.put(meta, :vsn, String.to_charlist(version))

    :ok =
      :file.write_file(
        Path.join(previous_ebin, "#{@app_name}.app") |> String.to_charlist(),
        :io_lib.fwrite(~c"~p.\n", [{:application, app, previous_meta}])
      )
  end

  @tag :capture_log
  test "returns :ok and skips appup generation when no previous release version exists" do
    # No release has been assembled under _build/test/rel/<app>, so there is
    # nothing to diff against and generation should be a no-op, not a crash.
    assert :ok = GenAppup.run(release_name: @app_name)
  end

  @tag :capture_log
  test "generates an appup when a previous release version is found" do
    version = Mix.Project.config()[:version]
    previous_version = "0.0.1"
    seed_previous_release(previous_version)

    assert :ok = GenAppup.run(release_name: @app_name)

    appup_dir = Path.join(["rel", "appups", "#{@app_name}"])
    assert File.exists?(Path.join(appup_dir, "#{previous_version}_to_#{version}.appup"))
    assert File.exists?(Path.join(appup_dir, "jellyfish.json"))

    jellyfish_json =
      appup_dir |> Path.join("jellyfish.json") |> File.read!() |> Jason.decode!()

    app_name_str = to_string(@app_name)

    assert %{
             "name" => ^app_name_str,
             "type" => "project",
             "from" => ^previous_version,
             "to" => ^version,
             "format_version" => 1,
             "generator" => generator
           } = jellyfish_json

    assert generator =~ ~r|^jellyfish/\d+\.\d+\.\d+|
  end

  describe "with an override" do
    setup do
      version = Mix.Project.config()[:version]
      seed_previous_release("0.0.1")

      %{version: version, generated: "rel/appups/#{@app_name}/0.0.1_to_#{version}.appup"}
    end

    defp write_override!(app, name, contents) do
      path = Path.join(["rel", "appup_overrides", "#{app}", name])
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
      path
    end

    test "uses the appup written by hand for this upgrade, as it is", ctx do
      override = """
      %% The generated instructions do not work for this upgrade, these stop and start it.
      {"#{ctx.version}",
       [{"0.0.1", [{stop, ['Elixir.Jellyfish']}, {start, ['Elixir.Jellyfish']}]}],
       [{"0.0.1", []}]}.
      """

      path = write_override!(@app_name, "0.0.1_to_#{ctx.version}.appup", override)

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = GenAppup.run(release_name: @app_name)
        end)

      assert output =~ "from the override #{path}"

      # With its comments, which say why it was written
      assert File.read!(ctx.generated) == override

      assert %{"from" => "0.0.1", "to" => to} =
               "rel/appups/#{@app_name}/jellyfish.json" |> File.read!() |> Jason.decode!()

      assert to == ctx.version
    end

    @tag :capture_log
    test "ignores the override of another upgrade", ctx do
      write_override!(@app_name, "0.0.1_to_9.9.9.appup", """
      {"9.9.9", [{"0.0.1", [{stop, ['Elixir.Jellyfish']}]}], [{"0.0.1", []}]}.
      """)

      write_override!(:another_app, "0.0.1_to_#{ctx.version}.appup", """
      {"#{ctx.version}", [{"0.0.1", [{stop, ['Elixir.Jellyfish']}]}], [{"0.0.1", []}]}.
      """)

      assert :ok = GenAppup.run(release_name: @app_name)

      # The previous release is a copy of the current one, so nothing changed
      assert {:ok, [{_to, [{~c"0.0.1", []}], [{~c"0.0.1", []}]}]} =
               :file.consult(String.to_charlist(ctx.generated))
    end

    @tag :capture_log
    test "fails the build when the override is not an appup for the versions of its name",
         ctx do
      for contents <- [
            ~s|{"9.9.9", [{"0.0.1", []}], [{"0.0.1", []}]}.\n|,
            ~s|{"#{ctx.version}", [{"0.0.2", []}], [{"0.0.2", []}]}.\n|,
            "not_an_appup.\n",
            "{unterminated"
          ] do
        write_override!(@app_name, "0.0.1_to_#{ctx.version}.appup", contents)

        assert {:error, [%Mix.Task.Compiler.Diagnostic{severity: :error, message: message}]} =
                 GenAppup.run(release_name: @app_name)

        assert message =~ "invalid_override"
        refute File.exists?(ctx.generated)
      end
    end

    @tag :capture_log
    test "says which versions the override has when they are not the expected ones", ctx do
      # No downgrade, which the relup of a hot upgrade is also built with
      write_override!(
        @app_name,
        "0.0.1_to_#{ctx.version}.appup",
        ~s|{"#{ctx.version}", [{"0.0.1", []}], []}.\n|
      )

      assert {:error, [%Mix.Task.Compiler.Diagnostic{message: message}]} =
               GenAppup.run(release_name: @app_name)

      version = inspect(ctx.version)

      assert message =~
               ~s|expected: [to: #{version}, upgrade_from: ["0.0.1"], downgrade_to: ["0.0.1"]]|

      assert message =~ ~s|got: [to: #{version}, upgrade_from: ["0.0.1"], downgrade_to: []]|
    end
  end

  @tag :capture_log
  test "when multiple previous releases exist, upgrades from the highest version" do
    version = Mix.Project.config()[:version]
    seed_previous_release("0.0.1")
    seed_previous_release("0.0.2")

    assert :ok = GenAppup.run(release_name: @app_name)

    appup_dir = Path.join(["rel", "appups", "#{@app_name}"])
    assert File.exists?(Path.join(appup_dir, "0.0.2_to_#{version}.appup"))
    refute File.exists?(Path.join(appup_dir, "0.0.1_to_#{version}.appup"))
  end

  @tag :capture_log
  test "also generates a no-op appup for a declared production dependency that is not yet loaded" do
    fake_app_root = Path.join(System.tmp_dir!(), "jellyfish_gen_appup_test_fakeapp")
    fake_app_ebin = Path.join(fake_app_root, "fakeapp-0.1.0/ebin")
    File.rm_rf!(fake_app_root)
    File.mkdir_p!(fake_app_ebin)

    File.write!(
      Path.join(fake_app_ebin, "fakeapp.app"),
      "{application, fakeapp, [{vsn, \"0.1.0\"}, {applications, []}, {description, \"\"}, {modules, []}]}."
    )

    Application.unload(:fakeapp)
    fake_app_ebin_path = String.to_charlist(fake_app_ebin)
    :code.add_patha(fake_app_ebin_path)

    on_exit(fn ->
      :code.del_path(fake_app_ebin_path)
      Application.unload(:fakeapp)
      File.rm_rf!(fake_app_root)
    end)

    Mix.Project.push(Mix.Tasks.Compile.GenAppupTest.FixtureProject)
    on_exit(fn -> Mix.Project.pop() end)

    assert :ok = GenAppup.run(release_name: @app_name)
  end

  describe "transitive dependencies" do
    setup do
      shell = Mix.shell()
      Mix.shell(Mix.Shell.Process)

      # Mix resolves the dependencies of a nested project from the project
      # below it, so the fixture has to replace this project, not sit on top.
      %{name: name, file: file} = Mix.Project.pop()
      Mix.Project.push(Mix.Tasks.Compile.GenAppupTest.TransitiveFixtureProject, file)

      on_exit(fn ->
        Mix.Project.pop()
        Mix.Project.push(name, file)
        Mix.shell(shell)
      end)

      :ok
    end

    @tag :capture_log
    test "checks the dependencies that a declared production dependency brings in" do
      assert :ok = GenAppup.run(release_name: @app_name)

      for app <- ["mix_audit", "jason", "yaml_elixir", "yamerl"] do
        assert processed?(app), "expected #{app} to be checked for appups"
      end
    end

    @tag :capture_log
    test "skips the transitive dependencies that the release does not ship" do
      assert :ok =
               GenAppup.run(release_name: @app_name, release_apps: [:mix_audit, :yaml_elixir])

      assert processed?("mix_audit")
      assert processed?("yaml_elixir")
      refute processed?("jason")
      refute processed?("yamerl")
    end

    # Each processed app is reported on the shell as "[app] versions: ..."
    defp processed?(app) do
      {:messages, messages} = Process.info(self(), :messages)

      Enum.any?(messages, fn
        {:mix_shell, :info, [message]} -> IO.chardata_to_string(message) =~ "[#{app}]"
        _other -> false
      end)
    end
  end

  @tag :capture_log
  test "returns an error diagnostic, instead of crashing, when Appup.make reports a version mismatch" do
    current_ebin = Path.join(Application.app_dir(@app_name), "ebin")
    current_app_file = Path.join(current_ebin, "#{@app_name}.app")
    original_app_file_contents = File.read!(current_app_file)

    on_exit(fn -> File.write!(current_app_file, original_app_file_contents) end)

    previous_version = "0.0.1"
    previous_ebin = Path.join([@output_dir, "lib", "#{@app_name}-#{previous_version}", "ebin"])
    File.mkdir_p!(previous_ebin)

    for entry <- File.ls!(current_ebin) do
      File.cp!(Path.join(current_ebin, entry), Path.join(previous_ebin, entry))
    end

    {:ok, [{:application, app, meta}]} =
      Path.join(previous_ebin, "#{@app_name}.app") |> :file.consult()

    previous_meta = Keyword.put(meta, :vsn, String.to_charlist(previous_version))

    :ok =
      :file.write_file(
        Path.join(previous_ebin, "#{@app_name}.app") |> String.to_charlist(),
        :io_lib.fwrite(~c"~p.\n", [{:application, app, previous_meta}])
      )

    # Simulate the currently-loaded app's on-disk .app file drifting away
    # from what Application.spec/1 already has cached in memory - the one
    # way Appup.make's own version check can actually fail at this point.
    tampered_meta = Keyword.put(meta, :vsn, ~c"9.9.9")

    :ok =
      :file.write_file(
        String.to_charlist(current_app_file),
        :io_lib.fwrite(~c"~p.\n", [{:application, app, tampered_meta}])
      )

    assert {:error, [%Mix.Task.Compiler.Diagnostic{compiler_name: "GenAppup"}]} =
             GenAppup.run(release_name: @app_name)
  end
end
