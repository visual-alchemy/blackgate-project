defmodule Blackgate.DbSdiValidationTest do
  use ExUnit.Case, async: false
  alias Blackgate.Db
  alias Blackgate.License

  @sdi_error "SDI output not supported on Blackgate Lite"

  setup do
    original = :sys.get_state(License)

    :sys.replace_state(License, fn state ->
      Map.put(state, :cache, %{
        status: :licensed,
        deadline: nil,
        offline_deadline: nil,
        max_routes: 16,
        plan: "pro",
        client: "Lite test"
      })
    end)

    send(License, :checkpoint)
    :sys.get_state(License)
    :khepri.delete_many("routes/**")

    on_exit(fn ->
      :khepri.delete_many("routes/**")
      :sys.replace_state(License, fn _ -> original end)
      send(License, :checkpoint)
      :sys.get_state(License)
    end)

    :ok
  end

  test "create_route/1 (POST /api/routes handler) rejects SDI destination" do
    attrs = %{
      "name" => "sdi-reject-test",
      "destinations" => [
        %{"schema" => "SDI", "schema_options" => %{"device_number" => 0, "video_mode" => 9}}
      ]
    }

    assert {:error, @sdi_error} = Db.create_route(attrs)
  end

  test "update_route/2 rejects SDI destination" do
    {:ok, route} = Db.create_route(%{"name" => "sdi-reject-update-test"})

    attrs = %{
      "destinations" => [
        %{"schema" => "SDI", "schema_options" => %{"device_number" => 1}}
      ]
    }

    assert {:error, @sdi_error} = Db.update_route(route["id"], attrs)
  end

  test "create_destination/3 rejects SDI destination" do
    {:ok, route} = Db.create_route(%{"name" => "sdi-reject-dest-test"})

    assert {:error, @sdi_error} =
             Db.create_destination(route["id"], %{
               "schema" => "SDI",
               "schema_options" => %{"device_number" => 0}
             })
  end

  test "update_destination/3 rejects changing a destination to SDI" do
    {:ok, route} = Db.create_route(%{"name" => "sdi-reject-dest-update-test"})

    {:ok, destination} =
      Db.create_destination(route["id"], %{
        "schema" => "SRT",
        "schema_options" => %{"localaddress" => "127.0.0.1", "localport" => 4203}
      })

    assert {:error, @sdi_error} =
             Db.update_destination(route["id"], destination["id"], %{"schema" => "SDI"})
  end

  test "non-SDI route creation still succeeds" do
    attrs = %{
      "name" => "sdi-reject-allowed-test",
      "destinations" => [
        %{
          "schema" => "SRT",
          "schema_options" => %{"localaddress" => "127.0.0.1", "localport" => 4202}
        }
      ]
    }

    assert {:ok, %{"id" => _}} = Db.create_route(attrs)
  end

  test "UDP route creation still succeeds" do
    attrs = %{
      "name" => "udp-allowed-test",
      "destinations" => [
        %{
          "schema" => "UDP",
          "schema_options" => %{"host" => "127.0.0.1", "port" => 4204}
        }
      ]
    }

    assert {:ok, %{"id" => _}} = Db.create_route(attrs)
  end
end
