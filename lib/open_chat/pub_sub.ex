defmodule OpenChat.PubSub do
  @moduledoc false

  def subscribe(key), do: Registry.register(__MODULE__, key, %{})

  def broadcast(keys, event) when is_list(keys) do
    keys = Enum.uniq(keys)
    local_broadcast(keys, event)
    OpenChat.RedisBus.publish(keys, event)
    :ok
  end

  def broadcast(key, event), do: broadcast([key], event)

  def local_broadcast(keys, event) when is_list(keys) do
    Enum.each(Enum.uniq(keys), &local_broadcast(&1, event))
  end

  def local_broadcast(key, event) do
    Registry.dispatch(__MODULE__, key, fn entries ->
      for {pid, _meta} <- entries, do: send(pid, {:comet_event, event})
    end)

    :ok
  end
end
