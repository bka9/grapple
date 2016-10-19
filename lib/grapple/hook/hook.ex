defmodule Grapple.Hook do
  @moduledoc """
  This module provides a GenServer that is primarily responsible for subscribing
  to and broadcasting Webhooks. It also defines a `Hook` struct, and macros
  for defining hooks.
  """
  use GenServer
  alias Experimental.Flow, as: Flow

  alias Grapple.Logger
  alias Grapple.Hook.Server, as: HookServer

  @http Application.get_env(:grapple, :http)

  # TODO: should probably make this configurable for users
  @enforce_keys [:topic, :url]
  defstruct [
    :topic,
    :url,
    :owner,
    :life,
    :ref,
    method: "GET",
    headers: [],
    body: %{},
    query: %{},
  ]

  # API

  @doc false
  def start_link(stash_pid) do
    GenServer.start_link __MODULE__, stash_pid, name: __MODULE__
  end

  @doc """
  Callback for subscribing a Webhook. Adds a unique ref,
  adds to the list, and returns the topic name and unique ref of that Webhook.
  """
  def subscribe(webhook = %Grapple.Hook{}) do
    GenServer.call __MODULE__, {:subscribe, webhook}
  end

  @doc """
  Returns all webhooks.
  """
  def get_webhooks do
    GenServer.call __MODULE__, :get_webhooks
  end

  @doc """
  Returns all topics.
  """
  def get_topics do
    GenServer.call __MODULE__, :get_topics
  end

  @doc """
  Executes an HTTP request for every Webhook of the
  specified topic, and returns the current logs.
  """
  def broadcast(topic) do
    GenServer.call __MODULE__, {:broadcast, topic}
  end
  def broadcast(topic, body) when is_nil(body) do
    GenServer.call __MODULE__, {:broadcast, topic}
  end
  def broadcast(topic, body) do
    GenServer.call __MODULE__, {:broadcast, topic, body}
  end

  @doc """
  Clears out all webhooks from the stash.
  """
  def clear_webhooks do
    GenServer.call __MODULE__, :clear_webhooks
  end


  @doc """
  Removes a single webhook by reference.
  """
  def remove_webhook(ref) when is_reference(ref) do
    GenServer.cast __MODULE__, {:remove_webhook, ref}
  end

  @doc """
  Removes all webhooks under a certain topic,
  by topic name.
  """
  def remove_topic(topic) when is_binary(topic) do
    GenServer.cast __MODULE__, {:remove_topic, topic}
  end

  # Callbacks

  @doc false
  def init(stash_pid) do
    webhooks = HookServer.get_hooks stash_pid
    {:ok, {webhooks, stash_pid}}
  end

  @doc """
  If the server is about to exit (i.e. crashing),
  save the current state in the stash.
  """
  def terminate(_reason, {webhooks, stash_pid}) do
    HookServer.save_hooks stash_pid, webhooks
  end


  def handle_call({:subscribe, webhook}, _from, state = {webhooks, stash_pid}) do
    if webhook in webhooks do
      {:reply, {webhook.topic, webhook.ref}, state}
    else
      webhook = Map.put(webhook, :ref, make_ref())
      {:reply, {webhook.topic, webhook.ref}, {[webhook | webhooks], stash_pid}}
    end
  end

  def handle_call(:get_webhooks, _from, state = {webhooks, _stash_pid}) do
    {:reply, webhooks, state}
  end

  def handle_call(:get_topics, _from, state = {webhooks, _status_pid}) do
    topics = webhooks
      |> Enum.map(&(&1.topic))

    {:reply, topics, state}
  end

  def handle_call({:broadcast, topic}, _from, {webhooks, stash_pid}) do
    webhooks
      |> Flow.from_enumerable()
      |> Flow.filter(&(&1.topic == topic))
      |> Flow.map(fn webhook -> notify(webhook, webhook.body) end)
      |> Enum.to_list()

    {:reply, Logger.get_logs, {webhooks, stash_pid}}
  end

  def handle_call({:broadcast, topic, body}, _from, {webhooks, stash_pid}) do
    responses = webhooks
      |> Flow.from_enumerable()
      |> Flow.filter(&(&1.topic == topic))
      |> Flow.map(fn webhook -> notify(webhook, body) end)
      |> Enum.to_list()

    {:reply, responses, {webhooks, stash_pid}}
  end

  def handle_call(:clear_webhooks, _from, {_webhooks, stash_pid}) do
    {:reply, :ok, {[], stash_pid}}
  end

  def handle_cast({:remove_webhook, ref}, {webhooks, stash_pid}) do
    webhooks = webhooks
      |> Enum.reject(&(&1.ref == ref))
    {:noreply, {webhooks, stash_pid}}
  end

  def handle_cast({:remove_topic, topic}, {webhooks, stash_pid}) do
    webhooks = webhooks
      |> Enum.reject(&(&1.topic == topic))
    {:noreply, {webhooks, stash_pid}}
  end

  # Helpers

  @doc """
  Messages a subscriber webhook with the latest updates via HTTP
  """
  defp notify(webhook, body) do
    _notify(webhook, body)
    |> handle_response
    |> Logger.add_log(webhook)
  end

  defp _notify(webhook = %Grapple.Hook{method: "GET"}, _body) do
    @http.get(webhook.url, webhook.headers)
  end
  defp _notify(webhook = %Grapple.Hook{method: "POST"}, body) do
    @http.post(webhook.url, webhook.headers, body)
  end
  defp _notify(webhook = %Grapple.Hook{method: "PUT"}, body) do
    @http.put(webhook.url, webhook.headers, body)
  end
  defp _notify(webhook = %Grapple.Hook{method: "DELETE"}, _body) do
    @http.delete(webhook.url, webhook.headers)
  end

  defp handle_response(response) do
    case response do
      {:ok, %{status_code: 200, body: body}} ->
        {:success, body: body}
      {:ok, %{status_code: 404}} ->
        #delete subscrip
        :not_found
      {:error, %{reason: reason}} ->
        {:error, reason: reason}
    end
  end

  # Macros

  @doc """
  Allows modules to `use` Grapple.Hook in them
  """
  defmacro __using__(_opts) do
    quote do
      import Grapple.Hook
    end
  end

  @doc """
  Provides a unique topic based on an arbitrary name and the lexical module
  """
  def topicof(name), do: "#{__MODULE__}.#{name}"

  @doc """
  Allows users to define hookable functions that automatically publish
  to subscribers whenever they are invoked
  """
  # TODO: Need logging service, no way to check results of hook sending.
  defmacro defhook(name, do: block) do
    id = Macro.to_string name

    quote do
      def unquote(name) do
        topic  = unquote id |> topicof
        result = unquote block

        broadcast topic, result

        result
      end
    end
  end
end