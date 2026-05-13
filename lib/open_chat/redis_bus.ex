defmodule OpenChat.RedisBus do
  @moduledoc false

  use GenServer
  require Logger

  alias OpenChat.Config

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def publish(keys, event) do
    if pid = Process.whereis(__MODULE__) do
      GenServer.cast(pid, {:publish, List.wrap(keys), event})
    end

    :ok
  end

  @impl true
  def init(_opts) do
    state = %{
      channel: channel(),
      origin: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false),
      pubsub: nil
    }

    case Config.redis_url() do
      url when is_binary(url) and url != "" ->
        case Redix.PubSub.start_link(url, name: OpenChat.RedisPubSub) do
          {:ok, pubsub} ->
            {:ok, _ref} = Redix.PubSub.subscribe(pubsub, state.channel, self())
            {:ok, %{state | pubsub: pubsub}}

          {:error, {:already_started, pubsub}} ->
            {:ok, _ref} = Redix.PubSub.subscribe(pubsub, state.channel, self())
            {:ok, %{state | pubsub: pubsub}}

          {:error, reason} ->
            Logger.warning("Redis event bus disabled: #{inspect(reason)}")
            {:ok, state}
        end

      _ ->
        {:ok, state}
    end
  end

  @impl true
  def handle_cast({:publish, _keys, _event}, %{pubsub: nil} = state), do: {:noreply, state}

  def handle_cast({:publish, keys, event}, state) do
    payload =
      Jason.encode!(%{
        "origin" => state.origin,
        "keys" => Enum.map(keys, &encode_key/1),
        "event" => event
      })

    if Process.whereis(OpenChat.Redis) do
      Redix.command(OpenChat.Redis, ["PUBLISH", state.channel, payload])
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:redix_pubsub, _pubsub, _ref, :message, %{channel: channel, payload: payload}},
        %{channel: channel} = state
      ) do
    with {:ok, %{"origin" => origin, "keys" => keys, "event" => event}} <- Jason.decode(payload),
         false <- origin == state.origin do
      keys
      |> Enum.map(&decode_key/1)
      |> Enum.reject(&is_nil/1)
      |> OpenChat.PubSub.local_broadcast(event)
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp channel, do: Config.redis_key_prefix() <> ":events"

  defp encode_key({type, id}), do: [to_string(type), to_string(id)]
  defp encode_key(other), do: ["raw", inspect(other)]

  defp decode_key([type, id]) when type in ["user", "group"], do: {String.to_atom(type), id}
  defp decode_key(_other), do: nil
end
