ExUnit.start()

# Blackgate.Application opens the Khepri store itself and treats a store it cannot open as fatal, so the test
# environment must not pre-start one: the second :khepri.start/1 answers :already_started and the node refuses to
# boot.
{:ok, _started_apps} = Application.ensure_all_started(:blackgate)
