defmodule Chaperon.Master do
  @moduledoc """
  Master process for running load tests. Initiates running a load test and awaits
  results from a run. Needs to be started before used.
  The Chaperon.Master process is started only once per cluster and registered
  globally as `Chaperon.Master`.
  """

  defstruct [
    id: nil,
    sessions: %{},
    tasks: %{}
  ]

  @type t :: %Chaperon.Master{
    id: atom,
    sessions: %{atom => Chaperon.Session.t},
    tasks: %{atom => pid}
  }

  use GenServer
  require Logger

  @name {:global, __MODULE__}

  def start do
    Chaperon.Master.Supervisor.start_master
  end

  def start_link do
    GenServer.start_link(__MODULE__, [], name: @name)
  end

  def init([]) do
    id = Node.self
    Logger.info "Starting Chaperon.Master #{id}"
    {:ok, %Chaperon.Master{id: id}}
  end

  def run_load_test(lt_mod, options \\ []) do
    # TODO: store result
    timeout = lt_mod.default_config[:loadtest_timeout] || :infinity

    result = GenServer.call(@name,
      {:run_load_test, lt_mod, run_options(options)},
      timeout
    )

    case result do
      {:remote, session, data} ->
        Chaperon.write_output(data, options[:output])
        session

      session ->
        session
    end
  end

  defp run_options(options) do
    case {:global.whereis_name(Chaperon.Master), options[:output]} do
      {_, nil} ->
        options

      {pid, output_path} when is_pid(pid) ->
        if local_pid?(pid) do
          options
        else
          options =
            options
            |> Keyword.merge(output: :remote)
        end
    end
  end

  def local_pid?(pid) do
    case inspect(pid) do
      "#PID<0." <> _ ->
        true
      _ ->
        false
    end
  end

  def handle_call({:run_load_test, lt_mod, options}, client, state) do
    Logger.info "Starting LoadTest #{lt_mod} @ Master #{state.id}"

    {:ok, _} = Task.start_link fn ->
      session = Chaperon.run_load_test(lt_mod, options)
      GenServer.cast @name, {:load_test_finished, lt_mod, session}
    end
    state = update_in state.tasks, &Map.put(&1, lt_mod, client)
    {:noreply, state}
  end

  def handle_cast({:load_test_finished, lt_mod, session}, state) do
    Logger.info "LoadTest finished: #{lt_mod}"
    client = state.tasks[lt_mod]
    GenServer.reply(client, session)
    state = update_in state.tasks, &Map.delete(&1, lt_mod)
    {:noreply, state}
  end
end
