defmodule RemoteRetroWeb.RetroChannel do
  use RemoteRetroWeb, :channel
  use SlenderChannel

  alias RemoteRetroWeb.{Presence, PresenceUtils}
  alias RemoteRetro.{Idea, Emails, Mailer, Retro, Vote}

  import ShorterMaps

  def join("retro:" <> retro_id, _, socket) do
    socket = assign(socket, :retro_id, retro_id)
    retro = Repo.get!(Retro, retro_id) |> Repo.preload([:ideas, :votes, :users])

    send self(), :after_join
    {:ok, retro, socket}
  end

  def handle_info(:after_join, socket) do
    PresenceUtils.track_timestamped(socket)
    push socket, "presence_state", Presence.list(socket)
    {:noreply, socket}
  end

  handle_in_and_broadcast("enable_idea_edit_state", ~m{id, editorToken})
  handle_in_and_broadcast("disable_idea_edit_state", ~m{id})
  handle_in_and_broadcast("user_typing_idea", ~m{userToken})
  handle_in_and_broadcast("live_edit_idea", ~m{id, liveEditText})
  handle_in_and_broadcast("highlight_idea", ~m{id, isHighlighted})

  def handle_in("idea_submitted", props, socket) do
    idea = add_idea! props, socket

    broadcast! socket, "idea_committed", idea
    {:noreply, socket}
  end

  def handle_in("idea_edited", ~m{id, body, category, assigneeId}, socket) do
    idea =
      Repo.get(Idea, id)
      |> Idea.changeset(~M{body, category, assignee_id: assigneeId})
      |> Repo.update!

    broadcast! socket, "idea_edited", idea
    {:noreply, socket}
  end

  def handle_in("idea_deleted", id, socket) do
    idea = Repo.delete!(%Idea{id: id})

    broadcast! socket, "idea_deleted", idea
    {:noreply, socket}
  end

  def handle_in("vote_submitted", %{"ideaId" => idea_id, "userId" => user_id}, socket) do
    retro_id = socket.assigns.retro_id
    user_vote_count = Retro.user_vote_count(~M{user_id, retro_id})

    if user_vote_count < 3 do
      broadcast! socket, "vote_submitted", ~m{idea_id, user_id}

      %Vote{idea_id: idea_id, user_id: user_id}
      |> Vote.changeset
      |> Repo.insert!
    end

    {:noreply, socket}
  end

  def handle_in("proceed_to_next_stage", %{"stage" => "closed"}, socket) do
    retro_id = socket.assigns.retro_id
    update_retro!(retro_id, "closed")
    Emails.action_items_email(retro_id) |> Mailer.deliver_now

    broadcast! socket, "proceed_to_next_stage", %{"stage" => "closed"}
    {:noreply, socket}
  end

  def handle_in("proceed_to_next_stage", ~m{stage}, socket) do
    update_retro!(socket.assigns.retro_id, stage)

    broadcast! socket, "proceed_to_next_stage", ~m{stage}
    {:noreply, socket}
  end

  def handle_in(unhandled_message, payload, socket) do
    error_payload = %{unhandled_message: %{type: unhandled_message, payload: payload}}
    Honeybadger.notify(error_payload, %{retro_id: socket.assigns.retro_id})

    {:reply, {:error, error_payload}, socket}
  end

  defp add_idea!(~m{body, category, userId, assigneeId}, socket) do
    %Idea{
      body: body,
      category: category,
      retro_id: socket.assigns.retro_id,
      user_id: userId,
      assignee_id: assigneeId
    }
    |> Idea.changeset
    |> Repo.insert!
  end

  defp update_retro!(retro_id, stage) do
    Repo.get(Retro, retro_id)
    |> Retro.changeset(~m{stage})
    |> Repo.update!
  end
end