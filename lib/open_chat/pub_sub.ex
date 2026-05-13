defmodule OpenChat.PubSub do
  @moduledoc false

  def subscribe(key), do: Registry.register(__MODULE__, key, %{})

  def broadcast(keys, event) when is_list(keys) do
    Enum.each(Enum.uniq(keys), &broadcast(&1, event))
  end

  def broadcast(key, event) do
    Registry.dispatch(__MODULE__, key, fn entries ->
      for {pid, _meta} <- entries, do: send(pid, {:comet_event, event})
    end)

    :ok
  end
end
