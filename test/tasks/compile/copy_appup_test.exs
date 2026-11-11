defmodule Mix.Tasks.Compile.CopyAppupTest.FixtureProject do
  @moduledoc false

  # Reuses the real project config but swaps in a fake production
  # dependency, so CopyAppup's dependency-copy loop (normally empty,
  # since this project has no runtime deps of its own) can be exercised.
  def project, do: Jellyfish.MixProject.project() |> Keyword.put(:deps, [{:fake_dep, ">= 0.0.0"}])
end

defmodule Mix.Tasks.Compile.CopyAppupTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Compile.CopyAppup

  @app_name Mix.Project.config()[:app]
  @version Mix.Project.config()[:version]
  @appup_dir "rel/appups/#{@app_name}"

  setup do
    File.rm_rf!(@appup_dir)

    on_exit(fn -> File.rm_rf!("rel") end)

    :ok
  end

  test "returns :ok without touching the release when no appup file exists" do
    release_path = Path.join(System.tmp_dir!(), "jellyfish_copy_appup_test_no_appup")
    File.rm_rf!(release_path)

    assert :ok = CopyAppup.run(release_path: release_path)
  end

  @tag :capture_log
  test "returns an error diagnostic, instead of crashing, when more than one appup file matches the target version" do
    File.mkdir_p!(@appup_dir)
    File.write!(Path.join(@appup_dir, "0.1.0_to_#{@version}.appup"), "{}.")
    File.write!(Path.join(@appup_dir, "0.1.1_to_#{@version}.appup"), "{}.")
    File.write!(Path.join(@appup_dir, "jellyfish.json"), "{}")

    release_path = Path.join(System.tmp_dir!(), "jellyfish_copy_appup_test_ambiguous")
    File.rm_rf!(release_path)

    assert {:error, [%Mix.Task.Compiler.Diagnostic{compiler_name: "CopyAppup"}]} =
             CopyAppup.run(release_path: release_path)
  end

  test "copies the appup and jellyfish files to the release when exactly one match is found" do
    File.mkdir_p!(@appup_dir)
    File.write!(Path.join(@appup_dir, "0.1.0_to_#{@version}.appup"), "{}.")
    File.write!(Path.join(@appup_dir, "jellyfish.json"), "{}")

    release_path = Path.join(System.tmp_dir!(), "jellyfish_copy_appup_test_single_match")
    destination_dir = "#{release_path}/lib/#{@app_name}-#{@version}/ebin"
    File.rm_rf!(release_path)
    File.mkdir_p!(destination_dir)

    assert :ok = CopyAppup.run(release_path: release_path)
    assert File.exists?("#{destination_dir}/#{@app_name}.appup")
    assert File.exists?("#{destination_dir}/jellyfish.json")
  end

  test "also copies appup files for a declared production dependency" do
    Mix.Project.push(Mix.Tasks.Compile.CopyAppupTest.FixtureProject)
    on_exit(fn -> Mix.Project.pop() end)

    Jellyfish.Cache.store_app_version(:fake_dep, "1.2.3")

    dep_appup_dir = "rel/appups/fake_dep"
    File.mkdir_p!(dep_appup_dir)
    File.write!(Path.join(dep_appup_dir, "0.1.0_to_1.2.3.appup"), "{}.")
    File.write!(Path.join(dep_appup_dir, "jellyfish.json"), "{}")

    release_path = Path.join(System.tmp_dir!(), "jellyfish_copy_appup_test_dependency")
    destination_dir = "#{release_path}/lib/fake_dep-1.2.3/ebin"
    File.rm_rf!(release_path)
    File.mkdir_p!(destination_dir)

    assert :ok = CopyAppup.run(release_path: release_path)
    assert File.exists?("#{destination_dir}/fake_dep.appup")
    assert File.exists?("#{destination_dir}/jellyfish.json")
  end

  test "pauses for a manual edit of the appup file when EDIT_APPUP is set" do
    System.put_env("EDIT_APPUP", "true")
    on_exit(fn -> System.delete_env("EDIT_APPUP") end)

    File.mkdir_p!(@appup_dir)
    File.write!(Path.join(@appup_dir, "0.1.0_to_#{@version}.appup"), "{}.")
    File.write!(Path.join(@appup_dir, "jellyfish.json"), "{}")

    release_path = Path.join(System.tmp_dir!(), "jellyfish_copy_appup_test_edit_appup")
    destination_dir = "#{release_path}/lib/#{@app_name}-#{@version}/ebin"
    File.rm_rf!(release_path)
    File.mkdir_p!(destination_dir)

    ExUnit.CaptureIO.capture_io("\n", fn ->
      assert :ok = CopyAppup.run(release_path: release_path)
    end)

    assert File.exists?("#{destination_dir}/#{@app_name}.appup")
    assert File.exists?("#{destination_dir}/jellyfish.json")
  end
end
