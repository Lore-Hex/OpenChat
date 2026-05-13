defmodule OpenChat.StoreRequestPlanTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.{Conversations, RequestPlan}

  test "message writes lock one conversation and refresh only touched records" do
    conversation_id = Conversations.user_conversation_id("plan-a", "plan-b")

    plan =
      RequestPlan.build(
        {:send_message, "plan-a",
         %{"receiver" => "plan-b", "receiverType" => "user", "data" => %{"text" => "hi"}}, [], []}
      )

    assert plan.mutating?
    assert plan.locks == [{:conversation, conversation_id}]

    assert plan.refresh == [
             {"users", "plan-a"},
             {:counter, "next_id"},
             {"conversation_messages", conversation_id},
             {"users", "plan-b"}
           ]
  end

  test "uid token auth plans both token and user keys" do
    plan = RequestPlan.build({:me, "uid:plan-user"})

    assert plan.mutating?
    assert plan.locks == [{:token, "uid:plan-user"}, {:user, "plan-user"}]
    assert plan.refresh == [{"users", "plan-user"}, {"tokens", "uid:plan-user"}]
  end

  test "local JWT auth plans against the underlying token" do
    jwt =
      "local." <>
        Base.url_encode64(Jason.encode!(%{"token" => "uid:jwt-plan-user"}), padding: false) <>
        ".unsigned"

    plan = RequestPlan.build({:authenticate, jwt})

    assert plan.mutating?
    assert plan.locks == [{:token, "uid:jwt-plan-user"}, {:user, "jwt-plan-user"}]
    assert plan.refresh == [{"users", "jwt-plan-user"}, {"tokens", "uid:jwt-plan-user"}]
  end

  test "opaque auth tokens follow up by refreshing the mapped user key" do
    state = %{"tokens" => %{"opaque-plan-token" => "mapped-plan-user"}}

    assert RequestPlan.followup_refresh({:me, "opaque-plan-token"}, state) == [
             {"users", "mapped-plan-user"}
           ]
  end

  test "read plans do not take Redis locks" do
    plan = RequestPlan.build({:get_message, "123"})

    refute plan.mutating?
    assert plan.locks == []
    assert plan.refresh == [{"messages", "123"}, {"reactions", "123"}]
  end

  test "message action follow-up refresh covers actor and group moderator records" do
    state = %{
      "messages" => %{
        "42" => %{"sender" => "sender", "receiverType" => "group", "receiver" => "room"}
      }
    }

    assert RequestPlan.followup_refresh({:delete_message, "moderator", "42", []}, state) == [
             {"users", "moderator"},
             {"users", "sender"},
             {"groups", "room"},
             {"members", "room"},
             {"banned", "room"}
           ]
  end

  test "broad store requests use indexed refreshes instead of whole-state refreshes" do
    requests = [
      {:list_users, %{}},
      {:blocked_users, "alice", %{"direction" => "hasBlockedMe"}},
      {:list_groups, %{}},
      {:delete_group, "room"},
      {:groups_for_user, "alice"},
      {:find_message_by_muid, "client-id"},
      {:unread_counts, "alice", %{}},
      {:conversations, "alice", %{}},
      {:delete_conversation, "user_alice_bob"}
    ]

    for request <- requests do
      plan = RequestPlan.build(request)
      refute :all in plan.refresh
      refute plan.refresh == []
    end

    assert RequestPlan.build({:conversations, "alice", %{}}).refresh == [
             {"user_conversations", "alice"},
             {"user_groups", "alice"},
             {"reads", "alice"},
             {"delivered", "alice"},
             {"hidden_conversations", "alice"}
           ]
  end
end
