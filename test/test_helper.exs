ExUnit.start()
{:ok, _started_apps} = Application.ensure_all_started(:blackgate)

if :khepri.get_store_ids() == [] do
  {:ok, :khepri} = :khepri.start(System.fetch_env!("DATABASE_DATA_DIR"))
end
