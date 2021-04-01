defmodule SpiderMan.Engine do
  @moduledoc false
  use GenServer, shutdown: 60_000
  alias SpiderMan.{Downloader, Spider, ItemPipeline, Requester, Utils}
  require Logger

  @type state :: map

  def process_name(spider), do: :"#{inspect(spider)}.Engine"

  def start_link(options) do
    spider = Keyword.fetch!(options, :spider)
    GenServer.start_link(__MODULE__, options, name: process_name(spider))
  end

  def status(spider), do: GenServer.call(process_name(spider), :status)

  def suspend(spider, timeout \\ :infinity) do
    process_name(spider)
    |> GenServer.call(:suspend, timeout)
  end

  # todo
  def suspend_and_dump_stat(spider, timeout \\ :infinity) do
    process_name(spider)
    |> GenServer.call(:suspend_and_dump_stat, timeout)
  end

  def continue(spider, timeout \\ :infinity) do
    process_name(spider)
    |> GenServer.call(:continue, timeout)
  end

  # todo
  def load_stat_and_continue(spider, timeout \\ :infinity) do
    process_name(spider)
    |> GenServer.call(:load_stat_and_continue, timeout)
  end

  @impl true
  def init(options) do
    state = Map.new(options) |> Map.put(:status, :preparing)
    Logger.info("!! spider: #{inspect(state.spider)} setup starting.")
    Process.flag(:trap_exit, true)

    {:ok, state, {:continue, :start_components}}
  end

  @impl true
  def handle_continue(:start_components, state) do
    spider = state.spider

    # new ets tables
    downloader_tid = :ets.new(:downloader, [:set, :public, write_concurrency: true])
    spider_tid = :ets.new(:spider, [:set, :public, write_concurrency: true])
    item_pipeline_tid = :ets.new(:item_pipeline, [:set, :public, write_concurrency: true])
    :persistent_term.put({spider, :downloader_tid}, downloader_tid)
    :persistent_term.put({spider, :spider_tid}, spider_tid)
    :persistent_term.put({spider, :item_pipeline_tid}, item_pipeline_tid)

    Logger.info("!! spider: #{inspect(spider)} setup ets tables finish.")

    # setup component's options
    downloader_options =
      [spider: spider, tid: downloader_tid, next_tid: spider_tid]
      |> Kernel.++(state.downloader_options)
      |> setup_finch(spider)
      |> prepare_for_start_component(:downloader, spider)

    spider_options =
      [spider: spider, tid: spider_tid, next_tid: item_pipeline_tid]
      |> Kernel.++(state.spider_options)
      |> prepare_for_start_component(:spider, spider)

    item_pipeline_options =
      [spider: spider, tid: item_pipeline_tid]
      |> Kernel.++(state.item_pipeline_options)
      |> setup_item_pipeline_context()
      |> prepare_for_start_component(:item_pipeline, spider)

    Logger.info("!! spider: #{inspect(spider)} setup prepare_for_start_component finish.")

    # start components
    {:ok, downloader_pid} = Supervisor.start_child(spider, {Downloader, downloader_options})
    {:ok, spider_pid} = Supervisor.start_child(spider, {Spider, spider_options})

    {:ok, item_pipeline_pid} =
      Supervisor.start_child(spider, {ItemPipeline, item_pipeline_options})

    Logger.info("!! spider: #{inspect(spider)} setup components finish.")

    state =
      Map.merge(state, %{
        status: :running,
        downloader_tid: downloader_tid,
        spider_tid: spider_tid,
        item_pipeline_tid: item_pipeline_tid,
        downloader_options: downloader_options,
        spider_options: spider_options,
        item_pipeline_options: item_pipeline_options,
        downloader_pid: downloader_pid,
        spider_pid: spider_pid,
        item_pipeline_pid: item_pipeline_pid
      })

    state =
      if function_exported?(spider, :prepare_for_start, 1) do
        spider.prepare_for_start(state)
      else
        state
      end

    Logger.info("!! spider: #{inspect(spider)} setup prepare_for_start finish.")

    Logger.info("!! spider: #{inspect(spider)} setup success.")
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:suspend, _from, %{status: :running} = state) do
    :ok = Utils.call_producer(state.downloader_pid, :suspend)
    :ok = Utils.call_producer(state.spider_pid, :suspend)
    :ok = Utils.call_producer(state.item_pipeline_pid, :suspend)
    {:reply, :ok, %{state | status: :suspend}}
  end

  def handle_call(:suspend, _from, state), do: {:reply, :ok, state}

  def handle_call(:continue, _from, %{status: :suspend} = state) do
    :ok = Utils.call_producer(state.downloader_pid, :continue)
    :ok = Utils.call_producer(state.spider_pid, :continue)
    :ok = Utils.call_producer(state.item_pipeline_pid, :continue)
    {:reply, :ok, %{state | status: :running}}
  end

  def handle_call(:continue, _from, state), do: {:reply, :ok, state}

  def handle_call(msg, _from, state) do
    Logger.warn("unsupported call msg: #{msg}.")
    {:reply, :upsupported, state}
  end

  @impl true
  def terminate(reason, state) do
    spider = state.spider
    level = if reason == :normal, do: :info, else: :warning
    Logger.log(level, "!! spider: #{inspect(spider)} terminate by reason: #{inspect(reason)}.")

    # prepare_for_stop
    prepare_for_stop_component(:downloader, state.downloader_options, spider)
    prepare_for_stop_component(:spider, state.spider_options, spider)
    prepare_for_stop_component(:item_pipeline, state.item_pipeline_options, spider)

    if function_exported?(spider, :prepare_for_stop, 1) do
      spider.prepare_for_stop(state)
    end

    Logger.log(level, "!! spider: #{inspect(spider)} prepare_for_stop finish.")

    Task.async(fn ->
      :ok = Supervisor.stop(spider, reason)
      Logger.log(level, "!! spider: #{inspect(spider)} stop finish.")
    end)

    :ok
  end

  defp prepare_for_start_component(options, component, spider) do
    if function_exported?(spider, :prepare_for_start_component, 2) do
      spider.prepare_for_start_component(component, options)
    else
      options
    end
  end

  defp prepare_for_stop_component(component, options, spider) do
    if function_exported?(spider, :prepare_for_stop_component, 2) do
      spider.prepare_for_stop_component(component, options)
    end

    Enum.each(
      Keyword.fetch!(options, :middlewares),
      &Utils.call_middleware_prepare_for_stop(&1)
    )
  end

  defp setup_finch(downloader_options, spider) do
    finch_name = :"#{spider}.Finch"

    retry_middleware = {
      Tesla.Middleware.Retry,
      delay: 500,
      max_retries: 3,
      max_delay: 4_000,
      should_retry: fn
        {:ok, %{status: status}} when status in [400, 500] -> true
        {:ok, _} -> false
        {:error, _} -> true
      end
    }

    finch_options =
      [
        spec_options: [pools: %{:default => [size: 32, count: 8]}],
        adapter_options: [pool_timeout: 5_000, receive_timeout: 5_000],
        middlewares: [retry_middleware],
        requester: Requester.Finch,
        request_options: []
      ]
      |> Keyword.merge(Keyword.get(downloader_options, :finch_options, []))

    finch_spec = {Finch, [{:name, finch_name} | finch_options[:spec_options]]}
    adapter_options = [{:name, finch_name} | finch_options[:adapter_options]]
    requester = finch_options[:requester]

    middlewares =
      case Keyword.get(finch_options, :base_url) do
        nil -> finch_options[:middlewares]
        base_url -> [{Tesla.Middleware.BaseUrl, base_url} | finch_options[:middlewares]]
      end

    request_options =
      [
        adapter_options: adapter_options,
        middlewares: middlewares
      ] ++ finch_options[:request_options]

    downloader_options
    |> Keyword.update(:additional_specs, [finch_spec], &[finch_spec | &1])
    |> Keyword.update(
      :context,
      %{requester: requester, request_options: request_options},
      fn context ->
        context
        |> Map.put(:requester, requester)
        |> Map.update(:request_options, request_options, &(request_options ++ &1))
      end
    )
  end

  defp setup_item_pipeline_context(item_pipeline_options) do
    storage = Keyword.get(item_pipeline_options, :storage, SpiderMan.Storage.Log)
    storage_options = Keyword.get(item_pipeline_options, :storage_options, [])

    context =
      item_pipeline_options
      |> Keyword.get(:context, %{})
      |> Map.merge(%{storage: storage, storage_options: storage_options})

    Keyword.put(item_pipeline_options, :context, context)
  end
end
