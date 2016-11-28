defmodule Cassandra.Ecto.Connection do
  use GenServer
  import Supervisor.Spec
  alias Cassandrex, as: C
  alias Cassandra.Ecto.Log

  @conn_opts [:keyspace, :auth, :ssl, :protocol_version,
    :pool_max_size, :pool_min_size, :pool_cull_interval]

  @default_host "127.0.0.1"
  @default_port 9042
  @default_timeout 5000
  @default_consistency :one

  def init({repo, opts}) do
    config = repo.__pool__
    name = pool_name(repo, opts)
    nodes = Keyword.get(config, :nodes, [{@default_host, @default_port}])
    conn_opts = prepare_conn_opts(config)
    conn_opts = Keyword.put_new(opts, :keyspace, Mix.env)
    if (opts[:use_keyspace] == false), do:
      conn_opts = Keyword.delete(conn_opts, :keyspace)
    C.add_nodes(name, nodes, conn_opts)
    {:ok, c} = C.get_client(name)
    {:ok, c}
  end

  defp prepare_conn_opts(config) do
    conn_opts = []
    for opt <- @conn_opts do
      if Keyword.has_key?(config, opt) do
        Keyword.put(conn_opts, opt, Keyword.get(config, opt))
      end
    end
    conn_opts
  end

  defp pool_name(repo, opts), do:
    Keyword.get(opts, :pool_name, repo.__pool_name__)

  def handle_call({:query, statement, values, opts}, _from, c) do
    res = C.query(c, statement, values, opts)
    {:reply, res, c}
  end
  def handle_call({:batch, queries, opts}, _from, c) do
    res = C.batch(c, queries, opts)
    {:reply, res, c}
  end

  def terminate(reason, c), do: C.close_client(c)

  def start_link(repo, opts) do
    name = pool_name(repo, opts)
    GenServer.start_link(__MODULE__, {repo, opts}, name: name)
  end

  def stop(repo, opts) do
    name = pool_name(repo, opts)
    GenServer.stop(name)
  end

  def query(repo, statement, values \\ [], opts \\ []) do
    name = pool_name(repo, opts)
    fn -> GenServer.call(name, {:query, statement, values, opts}) end
    |> with_log(repo, statement, values, opts)
  end

  def batch(repo, queries, opts \\ []) do
    name = pool_name(repo, opts)
    fn -> GenServer.call(name, {:batch, queries, opts}) end
    |> with_log(repo, queries, opts)
  end

  def child_spec(repo, opts), do: worker(__MODULE__, [repo, opts])

  defp with_log(res, repo, statement, values, opts) do
    case Keyword.get(opts, :log, false) do
      true  ->
        log(repo, statement, values, opts, res)
      false -> res.()
    end
  end
  defp with_log(res, repo, queries, opts) do
    case Keyword.get(opts, :log, false) do
      true ->
        statement = "BEGIN BATCH\n" <> Enum.map_join(queries, "\n", fn
          {statement, values} -> statement <> " " <> inspect(values)
        end) <> "\nAPPLY BATCH;"
        log(repo, statement, [], opts, res)
      false -> res.()
    end
  end
  defp log(repo, statement, values, opts, res) do
    start = :os.system_time(:nano_seconds)
    res = res.()
    connection_time = :os.system_time(:nano_seconds) - start
    entry = %{connection_time: connection_time, decode_time: nil,
      pool_time: nil, result: res, query: statement}
    Log.log(repo, values, entry, opts)
    res
  end
end
