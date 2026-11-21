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
end
