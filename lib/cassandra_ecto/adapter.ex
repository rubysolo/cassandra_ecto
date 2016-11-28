defmodule Cassandra.Ecto.Adapter do
  alias Cassandra.Ecto.Connection
  alias Ecto.Query
  import __MODULE__.CQL, only: [to_cql: 3, to_cql: 4, to_cql: 5]
  import Cassandra.Ecto.Helper

  def execute(repo, %{fields: fields}, {_cache, {func, query}}, params, process, opts) do
    cql = to_cql(func, query, opts)
    names = get_names(query)
    params = Enum.zip(names, params)
    case Connection.query(repo, cql, params, opts) do
      {:ok, %{rows: rows, num_rows: num}} -> {num, rows |> Enum.map(&process_row(&1, process, fields)) }
      {:error, err} -> raise err
    end
  end

  defp process_row(row, process, fields) do
    Enum.map_reduce(fields, row, fn
      {:&, _, [_, _, counter]} = field, acc ->
        {process.(field, acc, nil), []}
      field, [h|t] ->
        {process.(field, h, nil), t}
    end) |> elem(0)
  end

  def delete(repo, meta, fields, opts) do
    cql = to_cql(:delete, meta, fields, opts)

    {:ok, res} = Connection.query(repo, cql, fields, opts)
    {:ok, []}
  end


  def insert(_repo, meta, _params, _on_conflict, [_|_] = returning, _opts), do:
    read_write_error!(meta, returning)
  def insert(repo, meta, fields, {action, _, _} = on_conflict, [], opts) do
    cql = to_cql(:insert, meta, fields, on_conflict, opts)
    {:ok, res} = Connection.query(repo, cql, fields, opts)
    row = res.rows |> List.first
    case {row, action} do
      {nil,            :nothing} -> {:ok, []}
      {[true  | []],   :raise}   -> {:ok, []}
      {[false | data], :raise}   -> error! nil,
        "Unable to insert #{inspect(fields)}. Record #{inspect(Enum.zip(Keyword.keys(fields), data))} " <>
        "already exists. Use :insert_or_update for default upsert behaviour."
    end
  end

  def insert_all(repo, meta, header, rows, on_conflict, [_|_] = returning, _opts), do:
    read_write_error!(meta, returning)
  def insert_all(repo, meta, header, rows, on_conflict, [], opts) do
    queries = rows
    |> Enum.map(fn
      row -> {to_cql(:insert, meta, row, on_conflict, opts), row}
    end)
    Connection.batch(repo, queries, opts)
    {Enum.count(rows), []}
  end

  def update(_repo, meta, _fields, _filters, [_|_] = returning, _opts), do:
    read_write_error!(meta, returning)
  def update(repo, meta, fields, filters, [], opts) do
    cql = to_cql(:update, meta, fields, filters, opts)
    {:ok, res} = Connection.query(repo, cql, fields ++ filters, opts)
    {:ok, []}
  end

  defp read_write_error!(meta, returning), do:
    error! nil,
      "Cassandra adapter does not support :read_after_writes in models. " <>
      "The following fields in #{inspect meta.schema} are tagged as such: #{inspect returning}"

  def autogenerate(:id), do:
    error! nil,
      "Cassandra adapter does not support autogenerated :id field type in schema."
  def autogenerate(:embed_id),  do: Ecto.UUID.bingenerate()
  def autogenerate(:binary_id), do: Ecto.UUID.bingenerate()

  @datetimes [:datetime, :utc_datetime, :naive_datetime]

  # def loaders(:binary_id, type), do: [Ecto.UUID, type]
  def loaders(datetime, type) when datetime in @datetimes, do: [&timestamp_decode/1, type]
  def loaders({:embed, _} = type, _), do: [&load_embed(type, &1)]
  def loaders(_primitive, type), do: [type]

  # def dumpers(:binary_id, type), do: [type, Ecto.UUID]
  def dumpers(datetime, type) when datetime in @datetimes, do: [type, &timestamp_encode/1]
  def dumpers(_primitive, type), do: [type]

  defp load_embed({:embed, %{cardinality: :one, related: schema}} = type, value) do
    value = struct(schema, value)
    Ecto.Type.cast(type, value)
  end
  defp load_embed({:embed, %{cardinality: :many, related: schema}} = type, value) do
    value = value |> Enum.map(&struct(schema, &1))
    Ecto.Type.cast(type, value)
  end

  defp timestamp_decode(timestamp) do
    usec = timestamp |> rem(1_000_000)
    timestamp = timestamp |> div(1_000_000)
    {date, time} = :calendar.gregorian_seconds_to_datetime(timestamp)
    time = time |> Tuple.append(usec)
    {:ok, {date, time}}
  end

  defp timestamp_encode({{y, m, d}, {h, i, s, usec}}), do:
    {:ok, :calendar.datetime_to_gregorian_seconds({{y, m, d}, {h, i, s}}) * 1_000_000 + usec}

  def prepare(func, query), do: {:nocache, {func, query}}

end
