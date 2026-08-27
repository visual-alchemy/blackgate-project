defmodule Blackgate.DbSdiValidationTest do
  use ExUnit.Case, async: false
  alias Blackgate.Db

  @sdi_error "SDI output not supported on Blackgate Lite"

  # The test environment does not always keep the application-started Khepri
  # store alive, so ensure a store is running before exercising Db.
  setup do
    case :khepri.start("/tmp/blackgate_db_sdi_test_khepri") do
      {:ok, :khepri} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_started} -> :ok
      other -> flunk("cannot start khepri: #{inspect(other)}")
    end

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
end
