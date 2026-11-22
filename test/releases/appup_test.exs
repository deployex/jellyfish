defmodule Distillery.Test.AppupTest do
  use ExUnit.Case
  alias Jellyfish.Releases.Appup

  @fixtures_path Path.join([__DIR__, "..", "fixtures"])

  @v1_path Path.join([@fixtures_path, "appup_beams", "test-0.1.0"])
  @v2_path Path.join([@fixtures_path, "appup_beams", "test-0.2.0"])
  @v3_path Path.join([@fixtures_path, "appup_beams", "test-0.3.0"])

  @special_v1_path Path.join([@fixtures_path, "appup_beams", "special_proc-1.0.0"])
  @special_v2_path Path.join([@fixtures_path, "appup_beams", "special_proc-1.1.0"])

  test "v1 -> v2" do
    # Add ServerB and ServerC gen_servers, update Server to reference ServerB,
    # and ServerB will reference ServerC
    expected =
      {:ok,
       {~c"0.2.0",
        [
          {~c"0.1.0",
           [
             {:add_module, Test.ServerB},
             {:add_module, Test.ServerC},
             {:update, Test.Server, {:advanced, []}, []},
             {:update, Test.Supervisor, :supervisor}
           ]}
        ],
        [
          {~c"0.1.0",
           [
             {:delete_module, Test.ServerB},
             {:delete_module, Test.ServerC},
             {:update, Test.Server, {:advanced, []}, []},
             {:update, Test.Supervisor, :supervisor}
           ]}
        ]}}

    assert ^expected = Appup.make(:test, "0.1.0", "0.2.0", @v1_path, @v2_path)
  end

  test "v2 -> v3" do
    # Server changes to reference ServerC, and ServerC changes to reference ServerB,
    # ServerB changes to no references
    expected =
      {:ok,
       {~c"0.3.0",
        [
          {~c"0.2.0",
           [
             {:update, Test.Server, {:advanced, []}, []},
             {:update, Test.ServerB, {:advanced, []}, []},
             {:update, Test.ServerC, {:advanced, []}, []}
           ]}
        ],
        [
          {~c"0.2.0",
           [
             {:update, Test.Server, {:advanced, []}, []},
             {:update, Test.ServerB, {:advanced, []}, []},
             {:update, Test.ServerC, {:advanced, []}, []}
           ]}
        ]}}

    assert ^expected = Appup.make(:test, "0.2.0", "0.3.0", @v2_path, @v3_path)
  end

  test "uses an advanced update when code_change/3 is only exported by the new version" do
    # SpecialProc.Worker is a hand-rolled :gen_server callback module (no
    # `use GenServer` default). In 1.0.0 it exports no code_change/3. In
    # 1.1.0 it changes its state shape and adds code_change/3 to migrate
    # any process still holding the old-shape state. This is the ordinary
    # reason a module gains code_change/3 only in the new version, and the
    # appup must still issue an `:advanced` update so that migration code
    # actually runs, instead of a plain `:load_module` that would leave
    # existing processes running against old-shape state.
    assert {:ok, {~c"1.1.0", [{~c"1.0.0", up}], [{~c"1.0.0", down}]}} =
             Appup.make(:special_proc, "1.0.0", "1.1.0", @special_v1_path, @special_v2_path)

    assert up == [{:update, SpecialProc.Worker, {:advanced, []}, []}]
    assert down == [{:update, SpecialProc.Worker, {:advanced, []}, []}]
  end

  test "uses a soft update for OTP behaviour modules without code_change" do
    {v1_path, v2_path} = build_gen_server_fixture()

    assert {:ok, {~c"0.2.0", [{~c"0.1.0", up}], [{~c"0.1.0", down}]}} =
             Appup.make(:soft_proc, "0.1.0", "0.2.0", v1_path, v2_path)

    assert up == [{:update, :soft_proc_worker, :soft, []}]
    assert down == [{:update, :soft_proc_worker, :soft, []}]
  end

  test "ordinary modules without code_change still use load_module" do
    {v1_path, v2_path} = build_plain_module_fixture()

    assert {:ok, {~c"0.2.0", [{~c"0.1.0", up}], [{~c"0.1.0", down}]}} =
             Appup.make(:plain_proc, "0.1.0", "0.2.0", v1_path, v2_path)

    assert up == [{:load_module, :plain_worker}]
    assert down == [{:load_module, :plain_worker}]
  end

  test "returns an error when the declared previous version doesn't match the .app file" do
    assert {:error,
            {:appups,
             {:mismatched_versions, [version: :previous, expected: "9.9.9", got: "0.1.0"]}}} =
             Appup.make(:test, "9.9.9", "0.2.0", @v1_path, @v2_path)
  end

  test "returns an error when the previous version's .app file can't be read" do
    assert {:error, {:appups, :file, {:invalid_dotapp, _reason}}} =
             Appup.make(:test, "0.1.0", "0.2.0", "/nonexistent/path", @v2_path)
  end

  test "returns an error when the declared next version doesn't match the .app file" do
    assert {:error,
            {:appups, {:mismatched_versions, [version: :next, expected: "9.9.9", got: "0.2.0"]}}} =
             Appup.make(:test, "0.1.0", "9.9.9", @v1_path, @v2_path)
  end

  test "returns an error when the next version's .app file can't be read" do
    assert {:error, {:appups, :file, {:invalid_dotapp, _reason}}} =
             Appup.make(:test, "0.1.0", "0.2.0", @v1_path, "/nonexistent/path")
  end

  defp build_gen_server_fixture do
    build_compiled_fixture(
      :soft_proc,
      :soft_proc_worker,
      "-module(soft_proc_worker).\\n-behaviour(gen_server).\\n-export([init/1, handle_call/3]).\\ninit(_Args) -> {ok, v1}.\\nhandle_call(_Req, _From, State) -> {reply, ok, State}.\\n",
      "-module(soft_proc_worker).\\n-behaviour(gen_server).\\n-export([init/1, handle_call/3]).\\ninit(_Args) -> {ok, v2}.\\nhandle_call(_Req, _From, State) -> {reply, ok, State}.\\n"
    )
  end

  defp build_plain_module_fixture do
    build_compiled_fixture(
      :plain_proc,
      :plain_worker,
      "-module(plain_worker).\\n-export([value/0]).\\nvalue() -> v1.\\n",
      "-module(plain_worker).\\n-export([value/0]).\\nvalue() -> v2.\\n"
    )
  end

  defp build_compiled_fixture(app, module, v1_source, v2_source) do
    root = Path.join(System.tmp_dir!(), "jellyfish-appup-#{System.unique_integer([:positive])}")
    v1_path = Path.join(root, "v1")
    v2_path = Path.join(root, "v2")

    for {path, version, source} <- [
          {v1_path, "0.1.0", v1_source},
          {v2_path, "0.2.0", v2_source}
        ] do
      ebin = Path.join(path, "ebin")
      File.mkdir_p!(ebin)
      source_path = Path.join(root, Atom.to_string(module) <> "-#{version}.erl")
      File.write!(source_path, source)
      assert {:ok, ^module} = :compile.file(String.to_charlist(source_path), [
        :debug_info,
        {:outdir, String.to_charlist(ebin)}
      ])

      app_file = Path.join(ebin, Atom.to_string(app) <> ".app")
      File.write!(app_file, "{application, #{app}, [{vsn, \\\"#{version}\\\"}, {modules, [#{module}]}, {applications, [kernel, stdlib]}]}.\\n")
    end

    {v1_path, v2_path}
  end
end
