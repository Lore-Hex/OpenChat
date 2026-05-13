defmodule OpenChat.LoadPerfTest do
  use ExUnit.Case, async: false
  import Plug.Test

  alias OpenChat.Store
  alias OpenChatWeb.Endpoint

  @moduletag :load

  setup do
    old_redis_url = Application.get_env(:open_chat, :redis_url)
    Application.put_env(:open_chat, :redis_url, nil)
    restart_store!()

    on_exit(fn ->
      Application.put_env(:open_chat, :redis_url, old_redis_url)
      restart_store!()
    end)

    :ok
  end

  test "store sustains high-volume direct message writes and paginated reads" do
    users = env_int("OPENCHAT_LOAD_USERS", 100)
    messages = env_int("OPENCHAT_LOAD_MESSAGES", 2_000)
    minimum = env_int("OPENCHAT_MIN_STORE_MSG_PER_SEC", 300)

    {ids, seconds} =
      timed(fn ->
        Enum.map(1..messages, fn i ->
          sender = load_user(i, users)
          receiver = load_user(i + 1, users)

          assert {:ok, message} =
                   Store.send_message(sender, %{
                     "receiver" => receiver,
                     "receiverType" => "user",
                     "type" => "text",
                     "data" => %{"text" => "load #{i}"}
                   })

          message["id"]
        end)
      end)

    assert Enum.uniq(ids) == ids
    assert_rate("store direct messages", messages, seconds, minimum)

    assert {:ok, [_ | _]} =
             Store.messages_for_user(load_user(2, users), load_user(1, users), %{"limit" => 100})

    assert {:ok, [_ | _]} = Store.conversations(load_user(1, users), %{"limit" => 50})
  end

  test "concurrent Store writers preserve monotonic IDs under same-conversation contention" do
    concurrency = env_int("OPENCHAT_LOAD_CONCURRENCY", 16)
    per_worker = env_int("OPENCHAT_LOAD_WORKER_MESSAGES", 150)
    total = concurrency * per_worker
    minimum = env_int("OPENCHAT_MIN_CONCURRENT_STORE_MSG_PER_SEC", 200)

    {ids, seconds} =
      timed(fn ->
        concurrent_map(1..total, concurrency, fn i ->
          assert {:ok, message} =
                   Store.send_message("concurrent-store-a", %{
                     "receiver" => "concurrent-store-b",
                     "receiverType" => "user",
                     "type" => "text",
                     "data" => %{"text" => "concurrent store #{i}"}
                   })

          message["id"]
        end)
      end)

    assert length(ids) == total
    assert ids |> MapSet.new() |> MapSet.size() == total
    assert Enum.min(ids) == 1
    assert Enum.max(ids) == total
    assert_rate("concurrent store messages", total, seconds, minimum)
  end

  test "group fanout plus read and delivered receipts keep conversation cursors stable" do
    members = env_int("OPENCHAT_LOAD_GROUP_MEMBERS", 150)
    messages = env_int("OPENCHAT_LOAD_GROUP_MESSAGES", 600)
    minimum = env_int("OPENCHAT_MIN_GROUP_MSG_PER_SEC", 100)
    guid = "load-room"
    uids = Enum.map(1..members, &"group-user-#{&1}")

    assert {:ok, _group} = Store.upsert_group(%{"guid" => guid, "type" => "public"})
    assert {:ok, _members} = Store.add_group_members(guid, uids)

    {sent, seconds} =
      timed(fn ->
        Enum.map(1..messages, fn i ->
          sender = Enum.at(uids, rem(i, members))

          assert {:ok, message} =
                   Store.send_message(sender, %{
                     "receiver" => guid,
                     "receiverType" => "group",
                     "type" => "text",
                     "data" => %{"text" => "group load #{i}"}
                   })

          message
        end)
      end)

    assert_rate("group messages", messages, seconds, minimum)
    last_id = List.last(sent)["id"]

    receipt_users = Enum.take(uids, min(members, 100))

    {_receipts, receipt_seconds} =
      timed(fn ->
        concurrent_map(receipt_users, env_int("OPENCHAT_LOAD_RECEIPT_CONCURRENCY", 16), fn uid ->
          assert {:ok, delivered} = Store.mark_delivered(uid, "group", guid, last_id)
          assert {:ok, read} = Store.mark_read(uid, "group", guid, last_id)
          {delivered, read}
        end)
      end)

    assert_rate(
      "group receipt writes",
      length(receipt_users) * 2,
      receipt_seconds,
      env_int("OPENCHAT_MIN_RECEIPT_PER_SEC", 100)
    )

    assert {:ok, conversation} = Store.conversation(List.first(uids), "group", guid)
    assert conversation["lastDeliveredMessageId"] == to_string(last_id)
    assert conversation["lastReadMessageId"] == to_string(last_id)
  end

  test "HTTP endpoint sustains message send and fetch load through Plug" do
    messages = env_int("OPENCHAT_LOAD_HTTP_MESSAGES", 500)
    minimum = env_int("OPENCHAT_MIN_HTTP_MSG_PER_SEC", 100)

    {_responses, seconds} =
      timed(fn ->
        Enum.map(1..messages, fn i ->
          body = %{
            "receiver" => "http-load-b",
            "receiverType" => "user",
            "type" => "text",
            "data" => %{"text" => "http #{i}"}
          }

          response =
            conn(:post, "/v3.0/messages", Jason.encode!(body))
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Conn.put_req_header("authtoken", "uid:http-load-a")
            |> Endpoint.call([])

          assert response.status == 201
          response
        end)
      end)

    assert_rate("HTTP messages", messages, seconds, minimum)

    response =
      conn(:get, "/v3.0/users/http-load-a/messages?limit=100")
      |> Plug.Conn.put_req_header("authtoken", "uid:http-load-b")
      |> Endpoint.call([])

    assert response.status == 200
    assert %{"data" => [_ | _]} = Jason.decode!(response.resp_body)
  end

  test "concurrent HTTP endpoint load preserves unique message IDs" do
    concurrency = env_int("OPENCHAT_LOAD_HTTP_CONCURRENCY", 12)
    per_worker = env_int("OPENCHAT_LOAD_HTTP_WORKER_MESSAGES", 50)
    total = concurrency * per_worker
    minimum = env_int("OPENCHAT_MIN_CONCURRENT_HTTP_MSG_PER_SEC", 100)

    {ids, seconds} =
      timed(fn ->
        concurrent_map(1..total, concurrency, fn i ->
          body = %{
            "receiver" => "http-concurrent-b",
            "receiverType" => "user",
            "type" => "text",
            "data" => %{"text" => "http concurrent #{i}"}
          }

          response =
            conn(:post, "/v3.0/messages", Jason.encode!(body))
            |> Plug.Conn.put_req_header("content-type", "application/json")
            |> Plug.Conn.put_req_header("authtoken", "uid:http-concurrent-a")
            |> Endpoint.call([])

          assert response.status == 201
          get_in(Jason.decode!(response.resp_body), ["data", "id"])
        end)
      end)

    assert length(ids) == total
    assert ids |> MapSet.new() |> MapSet.size() == total
    assert_rate("concurrent HTTP messages", total, seconds, minimum)
  end

  test "Redis write-through load uses scoped refresh and monotonic counters" do
    with_redis(fn context ->
      messages = env_int("OPENCHAT_LOAD_REDIS_MESSAGES", 300)
      minimum = env_int("OPENCHAT_MIN_REDIS_MSG_PER_SEC", 20)

      Redix.command!(context.redis, ["SET", redis_key(context, "counter", "next_id"), "10"])

      {ids, seconds} =
        timed(fn ->
          Enum.map(1..messages, fn i ->
            sender = "redis-load-#{rem(i, 20)}"
            receiver = "redis-load-#{rem(i + 1, 20)}"

            assert {:ok, message} =
                     Store.send_message(sender, %{
                       "receiver" => receiver,
                       "receiverType" => "user",
                       "type" => "text",
                       "data" => %{"text" => "redis #{i}"}
                     })

            message["id"]
          end)
        end)

      assert Enum.uniq(ids) == ids
      assert Enum.min(ids) >= 10
      assert redis_get(context, "counter", "next_id") == to_string(Enum.max(ids) + 1)
      assert_rate("Redis messages", messages, seconds, minimum)
    end)
  end

  test "concurrent Redis write-through load preserves counters and per-key indexes" do
    with_redis(fn context ->
      concurrency = env_int("OPENCHAT_LOAD_REDIS_CONCURRENCY", 8)
      per_worker = env_int("OPENCHAT_LOAD_REDIS_WORKER_MESSAGES", 60)
      total = concurrency * per_worker
      minimum = env_int("OPENCHAT_MIN_CONCURRENT_REDIS_MSG_PER_SEC", 20)

      Redix.command!(context.redis, ["SET", redis_key(context, "counter", "next_id"), "100"])

      {ids, seconds} =
        timed(fn ->
          concurrent_map(1..total, concurrency, fn i ->
            lane = rem(i, concurrency)

            assert {:ok, message} =
                     Store.send_message("redis-concurrent-#{lane}-a", %{
                       "receiver" => "redis-concurrent-#{lane}-b",
                       "receiverType" => "user",
                       "type" => "text",
                       "data" => %{"text" => "redis concurrent #{i}"}
                     })

            message["id"]
          end)
        end)

      assert length(ids) == total
      assert ids |> MapSet.new() |> MapSet.size() == total
      assert Enum.min(ids) >= 100
      assert redis_get(context, "counter", "next_id") == to_string(Enum.max(ids) + 1)
      assert length(redis_members(context, "index", "messages")) == total
      assert_rate("concurrent Redis messages", total, seconds, minimum)
    end)
  end

  test "concurrent Redis secondary-index reads stay consistent under write-through load" do
    with_redis(fn context ->
      concurrency = env_int("OPENCHAT_LOAD_REDIS_INDEX_CONCURRENCY", 8)
      messages = env_int("OPENCHAT_LOAD_REDIS_INDEX_MESSAGES", 240)
      minimum = env_int("OPENCHAT_MIN_REDIS_INDEX_OP_PER_SEC", 20)

      {sent, write_seconds} =
        timed(fn ->
          concurrent_map(1..messages, concurrency, fn i ->
            assert {:ok, message} =
                     Store.send_message("redis-index-a", %{
                       "receiver" => "redis-index-b",
                       "receiverType" => "user",
                       "muid" => "redis-index-muid-#{i}",
                       "type" => "text",
                       "data" => %{"text" => "redis index #{i}"}
                     })

            message
          end)
        end)

      assert length(sent) == messages
      assert_rate("Redis indexed writes", messages, write_seconds, minimum)

      {lookups, read_seconds} =
        timed(fn ->
          concurrent_map(sent, concurrency, fn message ->
            assert {:ok, fetched} = Store.find_message_by_muid(message["muid"])
            assert fetched["id"] == message["id"]

            assert {:ok, [_ | _]} = Store.conversations("redis-index-a", %{"limit" => 20})
            fetched["id"]
          end)
        end)

      assert lookups |> MapSet.new() |> MapSet.size() == messages
      assert "redis-index-a" in redis_members(context, "index", "user_conversations")
      assert "redis-index-b" in redis_members(context, "index", "user_conversations")
      assert_rate("Redis indexed reads", messages * 2, read_seconds, minimum)
    end)
  end

  defp with_redis(fun) do
    redis_url = System.get_env("REDIS_TEST_URL") || "redis://localhost:6379/15"

    case Redix.start_link(redis_url) do
      {:ok, redis} ->
        prefix = "open_chat:load:#{System.unique_integer([:positive])}"
        old_redis_url = Application.get_env(:open_chat, :redis_url)
        old_key_prefix = Application.get_env(:open_chat, :redis_key_prefix)
        old_snapshot_key = Application.get_env(:open_chat, :redis_snapshot_key)

        Application.put_env(:open_chat, :redis_url, redis_url)
        Application.put_env(:open_chat, :redis_key_prefix, prefix)
        Application.put_env(:open_chat, :redis_snapshot_key, "#{prefix}:legacy_snapshot")
        delete_prefix(redis, prefix)
        restart_store!()

        try do
          fun.(%{redis: redis, prefix: prefix})
        after
          Application.put_env(:open_chat, :redis_url, old_redis_url)
          Application.put_env(:open_chat, :redis_key_prefix, old_key_prefix)
          Application.put_env(:open_chat, :redis_snapshot_key, old_snapshot_key)
          restart_store!()
          delete_prefix(redis, prefix)
        end

      {:error, reason} ->
        IO.puts("Skipping Redis load test; Redis unavailable: #{inspect(reason)}")
        :ok
    end
  end

  defp timed(fun) do
    {microseconds, result} = :timer.tc(fun)
    {result, microseconds / 1_000_000}
  end

  defp assert_rate(label, count, seconds, minimum) do
    per_second = count / max(seconds, 0.001)
    IO.puts("#{label}: #{Float.round(per_second, 1)}/s over #{count} ops")
    assert per_second >= minimum
  end

  defp concurrent_map(inputs, concurrency, fun) do
    inputs
    |> Task.async_stream(fun,
      max_concurrency: concurrency,
      ordered: false,
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, value} ->
        value

      {:exit, reason} ->
        flunk("concurrent load task failed: #{Exception.format_exit(reason)}")
    end)
  end

  defp env_int(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {int, _rest} when int > 0 -> int
          _other -> default
        end
    end
  end

  defp load_user(i, users), do: "load-user-#{rem(i, users)}"

  defp restart_store! do
    if Process.whereis(OpenChat.Store) do
      :ok = Supervisor.terminate_child(OpenChat.Supervisor, OpenChat.Store)
    end

    if pid = Process.whereis(OpenChat.Redis) do
      Process.exit(pid, :kill)
      wait_until_stopped(OpenChat.Redis)
    end

    case Supervisor.restart_child(OpenChat.Supervisor, OpenChat.Store) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      other -> flunk("failed to restart OpenChat.Store: #{inspect(other)}")
    end
  end

  defp wait_until_stopped(name, attempts \\ 20)
  defp wait_until_stopped(_name, 0), do: :ok

  defp wait_until_stopped(name, attempts) do
    if Process.whereis(name) do
      Process.sleep(10)
      wait_until_stopped(name, attempts - 1)
    else
      :ok
    end
  end

  defp redis_get(context, parts) when is_list(parts),
    do: redis_get_raw(context, redis_key(context, parts))

  defp redis_get(context, part_a, part_b), do: redis_get(context, [part_a, part_b])

  defp redis_get_raw(context, key) do
    {:ok, value} = Redix.command(context.redis, ["GET", key])
    value
  end

  defp redis_members(context, parts) when is_list(parts) do
    {:ok, members} = Redix.command(context.redis, ["SMEMBERS", redis_key(context, parts)])
    members
  end

  defp redis_members(context, part_a, part_b), do: redis_members(context, [part_a, part_b])

  defp redis_key(context, parts) when is_list(parts), do: Enum.join([context.prefix | parts], ":")
  defp redis_key(context, part_a, part_b), do: redis_key(context, [part_a, part_b])

  defp delete_prefix(redis, prefix, cursor \\ "0") do
    {:ok, [next_cursor, keys]} =
      Redix.command(redis, ["SCAN", cursor, "MATCH", "#{prefix}:*", "COUNT", "1000"])

    if keys != [] do
      Redix.command!(redis, ["DEL" | keys])
    end

    if next_cursor != "0" do
      delete_prefix(redis, prefix, next_cursor)
    end
  end
end
