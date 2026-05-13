defmodule OpenChat.StoreRequestPlanTest do
  use ExUnit.Case, async: true

  alias OpenChat.Store.{AuthTokens, Conversations, RequestPlan}

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

  test "group membership actions reserve message IDs through the shared counter" do
    join_plan = RequestPlan.build({:join_group, "plan-room", "plan-user", %{}})
    leave_plan = RequestPlan.build({:leave_group, "plan-room", "plan-user"})

    assert join_plan.mutating?

    assert join_plan.refresh == [
             {"groups", "plan-room"},
             {"members", "plan-room"},
             {"banned", "plan-room"},
             {"users", "plan-user"},
             {"user_groups", "plan-user"},
             {:counter, "next_id"}
           ]

    assert leave_plan.mutating?

    assert leave_plan.refresh == [
             {"groups", "plan-room"},
             {"members", "plan-room"},
             {"banned", "plan-room"},
             {"user_groups", "plan-user"},
             {:counter, "next_id"}
           ]
  end

  test "local JWT auth plans against the underlying token" do
    jwt = AuthTokens.local_jwt("jwt-plan-user", "uid:jwt-plan-user")

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

  test "actor-aware read and receipt plans refresh access-control records by key" do
    direct_conversation = Conversations.user_conversation_id("alice", "bob")

    assert RequestPlan.build({:messages_for_thread, "alice", "55", %{}}).refresh == [
             {"messages", "55"},
             {"thread_messages", "55"}
           ]

    assert RequestPlan.build({:find_message_by_muid_for, "alice", "client-muid", []}).refresh == [
             {"message_muids", "client-muid"}
           ]

    assert RequestPlan.build({:mark_read, "alice", "user", "bob", "55"}).refresh == [
             {"conversation_messages", direct_conversation},
             {"users", "bob"},
             {"messages", "55"},
             {"reads", "alice"}
           ]

    assert RequestPlan.build({:mark_delivered, "alice", "group", "room", "77"}).refresh == [
             {"conversation_messages", "group_room"},
             {"groups", "room"},
             {"members", "room"},
             {"banned", "room"},
             {"messages", "77"},
             {"delivered", "alice"}
           ]

    assert RequestPlan.build(
             {:send_message, "alice",
              %{
                "receiver" => "bob",
                "receiverType" => "user",
                "parentId" => "55",
                "data" => %{"text" => "reply"}
              }, [], []}
           ).refresh == [
             {"users", "alice"},
             {:counter, "next_id"},
             {"conversation_messages", direct_conversation},
             {"messages", "55"},
             {"users", "bob"}
           ]
  end

  test "broad store requests use indexed refreshes instead of whole-state refreshes" do
    requests = [
      {:list_users, %{}},
      {:blocked_users, "alice", %{"direction" => "hasBlockedMe"}},
      {:list_groups, %{}},
      {:delete_group, "room"},
      {:groups_for_user, "alice"},
      {:get_message_for, "alice", "1", []},
      {:find_message_by_muid, "client-id"},
      {:find_message_by_muid_for, "alice", "client-id", []},
      {:messages_for_thread, "alice", "1", %{}},
      {:mark_read, "alice", "user", "bob", "1"},
      {:mark_delivered, "alice", "user", "bob", "1"},
      {:add_reaction, "alice", "1", "👍"},
      {:reactions, "alice", "1", nil},
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
