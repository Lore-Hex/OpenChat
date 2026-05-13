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

    Enum.each(Enum.take(uids, min(members, 100)), fn uid ->
      assert {:ok, _receipt} = Store.mark_delivered(uid, "group", guid, last_id)
      assert {:ok, _receipt} = Store.mark_read(uid, "group", guid, last_id)
    end)

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
