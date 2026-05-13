defmodule OpenChat.Store.RedisPersistence do
  @moduledoc false

  require Logger

  alias OpenChat.Config

  @buckets [
    "users",
    "tokens",
    "groups",
    "members",
    "messages",
    "conversation_messages",
    "thread_messages",
    "reads",
    "delivered",
    "hidden_conversations",
    "reactions",
    "blocks",
    "banned"
  ]

  @counters ["next_id", "next_reaction_id"]
  @version "4"
  @lock_ttl_ms 60_000
  @lock_attempts 600

  def load_or_seed(default_state, seed_fun) do
    case Config.redis_url() do
      nil ->
        seed_fun.()

      "" ->
        seed_fun.()

      url ->
        case start_redis(url) do
          {:ok, _pid} -> load(default_state, seed_fun)
          {:error, reason} -> redis_failed("connection", reason, seed_fun)
        end
    end
  end

  def enabled?, do: Process.whereis(OpenChat.Redis) != nil

  def refresh(default_state, fallback_state) do
    if enabled?() do
      case command(["GET", revision_key()]) do
        {:ok, nil} -> fallback_state
        {:ok, revision} -> maybe_refresh_state(default_state, fallback_state, to_int(revision))
        {:error, reason} -> redis_failed("state refresh", reason, fn -> fallback_state end)
      end
    else
      fallback_state
    end
  end

  def with_lock(fun) when is_function(fun, 0) do
    if enabled?() do
      lock_value = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

      case acquire_lock(lock_value, @lock_attempts) do
        :ok ->
          try do
            fun.()
          after
            release_lock(lock_value)
          end

        {:error, reason} ->
          raise "Redis lock failed: #{inspect(reason)}"
      end
    else
      fun.()
    end
  end

  def write([]), do: :ok

  def write(ops) do
    if Process.whereis(OpenChat.Redis) do
      ops
      |> List.wrap()
      |> Enum.flat_map(&commands_for_op/1)
      |> Kernel.++([["SET", meta_key(), @version]])
      |> Kernel.++([["INCR", revision_key()]])
      |> run_pipeline()
      |> remember_pipeline_revision()
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("Redis persist failed: #{Exception.message(e)}")
      :ok
  end

  def replace_all(state) do
    if Process.whereis(OpenChat.Redis) do
      delete_prefix_commands()
      |> Kernel.++(state_commands(state))
      |> Kernel.++([["SET", meta_key(), @version]])
      |> Kernel.++([["INCR", revision_key()]])
      |> run_pipeline()
      |> remember_pipeline_revision()
    else
      :ok
    end
  rescue
    e ->
      Logger.warning("Redis replace failed: #{Exception.message(e)}")
      :ok
  end

  def put(bucket, id, value), do: {:put, to_s(bucket), to_s(id), value}
  def delete(bucket, id), do: {:delete, to_s(bucket), to_s(id)}
  def counter(name, value), do: {:counter, to_s(name), value}

  def put_or_delete(bucket, id, value) when value in [nil, %{}, []],
    do: delete(bucket, id)

  def put_or_delete(bucket, id, value), do: put(bucket, id, value)

  def buckets, do: @buckets
  def counters, do: @counters

  defp start_redis(url) do
    case Process.whereis(OpenChat.Redis) do
      nil ->
        case Redix.start_link(url, name: OpenChat.Redis) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end

      pid ->
        {:ok, pid}
    end
  end

  defp load(default_state, seed_fun) do
    case command(["GET", meta_key()]) do
      {:ok, nil} -> load_legacy_snapshot_or_seed(default_state, seed_fun)
      {:ok, _version} -> read_state(default_state)
      {:error, reason} -> redis_failed("key load", reason, seed_fun)
    end
  end

  defp load_legacy_snapshot_or_seed(default_state, seed_fun) do
    case command(["GET", Config.redis_snapshot_key()]) do
      {:ok, nil} ->
        state = seed_fun.()
        replace_all(state)
        state

      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, state} ->
            state = Map.merge(default_state, state)
            replace_all(state)
            state

          {:error, reason} ->
            redis_failed("legacy snapshot decode", reason, seed_fun)
        end

      {:error, reason} ->
        redis_failed("legacy snapshot load", reason, seed_fun)
    end
  end

  defp read_state(default_state) do
    state =
      Enum.reduce(@buckets, default_state, fn bucket, acc ->
        Map.put(acc, bucket, read_bucket(bucket))
      end)

    state =
      Enum.reduce(@counters, state, fn counter, acc ->
        case command(["GET", counter_key(counter)]) do
          {:ok, nil} -> acc
          {:ok, value} -> Map.put(acc, counter, max(to_int(value), default_state[counter]))
          {:error, _reason} -> acc
        end
      end)

    remember_remote_revision()
    state
  end

  defp maybe_refresh_state(_default_state, fallback_state, revision) when revision == 0 do
    fallback_state
  end

  defp maybe_refresh_state(default_state, fallback_state, revision) do
    if revision == local_revision() do
      fallback_state
    else
      read_state(default_state)
    end
  end

  defp remember_remote_revision do
    case command(["GET", revision_key()]) do
      {:ok, revision} -> remember_revision(revision)
      _ -> :ok
    end
  end

  defp remember_pipeline_revision({:ok, results}) do
    results
    |> List.last()
    |> remember_revision()

    :ok
  end

  defp remember_pipeline_revision(_result), do: :ok

  defp remember_revision(revision) do
    Process.put(:open_chat_redis_revision, to_int(revision))
    :ok
  end

  defp local_revision do
    Process.get(:open_chat_redis_revision, 0)
  end

  defp read_bucket(bucket) do
    with {:ok, ids} <- command(["SMEMBERS", index_key(bucket)]) do
      Enum.reduce(ids, %{}, fn id, acc ->
        case command(["GET", record_key(bucket, id)]) do
          {:ok, nil} ->
            acc

          {:ok, json} ->
            case Jason.decode(json) do
              {:ok, value} -> Map.put(acc, id, value)
              {:error, _reason} -> acc
            end

          {:error, _reason} ->
            acc
        end
      end)
    else
      _ -> %{}
    end
  end

  defp commands_for_op({:put, bucket, id, value}) do
    [
      ["SET", record_key(bucket, id), Jason.encode!(value)],
      ["SADD", index_key(bucket), id]
    ]
  end

  defp commands_for_op({:delete, bucket, id}) do
    [
      ["DEL", record_key(bucket, id)],
      ["SREM", index_key(bucket), id]
    ]
  end

  defp commands_for_op({:counter, counter, value}) do
    [["SET", counter_key(counter), to_s(value)]]
  end

  defp commands_for_op({:replace_all, state}),
    do: delete_prefix_commands() ++ state_commands(state)

  defp commands_for_op(_op), do: []

  defp state_commands(state) do
    bucket_commands =
      @buckets
      |> Enum.flat_map(fn bucket ->
        state
        |> Map.get(bucket, %{})
        |> Enum.flat_map(fn {id, value} -> commands_for_op(put(bucket, id, value)) end)
      end)

    counter_commands =
      Enum.map(@counters, fn counter ->
        ["SET", counter_key(counter), to_s(Map.get(state, counter, 1))]
      end)

    bucket_commands ++ counter_commands
  end

  defp delete_prefix_commands(cursor \\ "0", commands \\ []) do
    case command(["SCAN", cursor, "MATCH", "#{Config.redis_key_prefix()}:*", "COUNT", "1000"]) do
      {:ok, [next_cursor, []]} when next_cursor != "0" ->
        delete_prefix_commands(next_cursor, commands)

      {:ok, [_next_cursor, []]} ->
        commands

      {:ok, [next_cursor, keys]} when next_cursor != "0" ->
        keys = Enum.reject(keys, &(&1 == lock_key()))
        delete_prefix_commands(next_cursor, delete_command(keys, commands))

      {:ok, [_next_cursor, keys]} ->
        keys = Enum.reject(keys, &(&1 == lock_key()))
        delete_command(keys, commands)

      {:error, reason} ->
        Logger.warning("Redis prefix scan failed: #{inspect(reason)}")
        commands
    end
  end

  defp run_pipeline([]), do: {:ok, []}

  defp run_pipeline(commands) do
    case Redix.pipeline(OpenChat.Redis, commands) do
      {:ok, results} ->
        {:ok, results}

      {:error, reason} ->
        Logger.warning("Redis pipeline failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp delete_command([], commands), do: commands
  defp delete_command(keys, commands), do: [["DEL" | keys] | commands]

  defp acquire_lock(_lock_value, 0), do: {:error, :timeout}

  defp acquire_lock(lock_value, attempts) do
    case command(["SET", lock_key(), lock_value, "NX", "PX", to_s(@lock_ttl_ms)]) do
      {:ok, "OK"} ->
        :ok

      {:ok, nil} ->
        Process.sleep(50)
        acquire_lock(lock_value, attempts - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp release_lock(lock_value) do
    script = """
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("DEL", KEYS[1])
    else
      return 0
    end
    """

    command(["EVAL", script, "1", lock_key(), lock_value])
    :ok
  end

  defp redis_failed(context, reason, seed_fun) do
    Logger.warning("Redis #{context} failed: #{inspect(reason)}; using seeds")
    seed_fun.()
  end

  defp command(args), do: Redix.command(OpenChat.Redis, args)

  defp key(parts),
    do: [Config.redis_key_prefix() | parts] |> Enum.map(&to_s/1) |> Enum.join(":")

  defp meta_key, do: key(["meta", "version"])
  defp revision_key, do: key(["meta", "revision"])
  defp lock_key, do: key(["lock", "store"])
  defp index_key(bucket), do: key(["index", bucket])
  defp record_key(bucket, id), do: key([bucket, id])
  defp counter_key(counter), do: key(["counter", counter])

  defp to_s(nil), do: ""
  defp to_s(value) when is_binary(value), do: value
  defp to_s(value), do: to_string(value)

  defp to_int(nil), do: 0
  defp to_int(value) when is_integer(value), do: value

  defp to_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  defp to_int(value), do: value |> to_s() |> to_int()
end
