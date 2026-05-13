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
end
