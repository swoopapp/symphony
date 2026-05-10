defmodule SymphonyElixir.Notion.Client do
  @moduledoc """
  Thin Notion REST client for polling task database entries.
  """

  require Logger
  alias SymphonyElixir.{Config, Linear.Issue}

  @notion_version "2022-06-28"
  @page_size 25
  @max_error_body_log_bytes 1_000

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker_config(tracker) do
      do_fetch_by_states(tracker.database_id, tracker.active_states, require_run_agent?: true)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker

      with :ok <- validate_tracker_config(tracker) do
        do_fetch_by_states(tracker.database_id, normalized_states, require_run_agent?: false)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    with :ok <- validate_tracker_config(Config.settings!().tracker) do
      fetch_pages_by_ids(ids, [])
    end
  end

  @spec update_page_properties(String.t(), map()) :: :ok | {:error, term()}
  def update_page_properties(page_id, fields) when is_binary(page_id) and is_map(fields) do
    with :ok <- validate_tracker_config(Config.settings!().tracker),
         {:ok, properties} <- build_update_properties(fields),
         {:ok, _response} <- patch_json("/pages/#{page_id}", %{"properties" => properties}) do
      :ok
    end
  end

  @spec append_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def append_comment(page_id, body) when is_binary(page_id) and is_binary(body) do
    trimmed_body = String.trim(body)

    if trimmed_body == "" do
      :ok
    else
      with :ok <- validate_tracker_config(Config.settings!().tracker),
           {:ok, _response} <-
             patch_json("/blocks/#{page_id}/children", %{
               "children" => comment_blocks(trimmed_body)
             }) do
        :ok
      end
    end
  end

  @doc false
  @spec normalize_page_for_test(map(), String.t()) :: Issue.t()
  def normalize_page_for_test(page, body) when is_map(page) and is_binary(body) do
    normalize_page(page, body)
  end

  @doc false
  @spec query_payload_for_test([String.t()], keyword()) :: map()
  def query_payload_for_test(states, opts \\ []) do
    query_payload(states, Keyword.get(opts, :require_run_agent?, false), Keyword.get(opts, :start_cursor))
  end

  defp validate_tracker_config(tracker) do
    cond do
      not is_binary(tracker.api_key) ->
        {:error, :missing_notion_api_token}

      not is_binary(tracker.database_id) ->
        {:error, :missing_notion_database_id}

      true ->
        :ok
    end
  end

  defp do_fetch_by_states(database_id, states, opts) do
    fetch_database_pages(database_id, states, Keyword.get(opts, :require_run_agent?, false), nil, [])
  end

  defp fetch_database_pages(database_id, states, require_run_agent?, start_cursor, acc_pages) do
    payload = query_payload(states, require_run_agent?, start_cursor)

    with {:ok, body} <- post_json("/databases/#{database_id}/query", payload),
         {:ok, pages, next_cursor} <- decode_query_response(body) do
      updated_pages = Enum.reverse(pages, acc_pages)

      case next_cursor do
        cursor when is_binary(cursor) ->
          fetch_database_pages(database_id, states, require_run_agent?, cursor, updated_pages)

        nil ->
          updated_pages
          |> Enum.reverse()
          |> normalize_pages_with_body([])
      end
    end
  end

  defp normalize_pages_with_body([], acc), do: {:ok, Enum.reverse(acc)}

  defp normalize_pages_with_body([page | rest], acc) do
    case fetch_page_body(page["id"]) do
      {:ok, body} ->
        normalize_pages_with_body(rest, [normalize_page(page, body) | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_pages_by_ids([], acc), do: {:ok, Enum.reverse(acc)}

  defp fetch_pages_by_ids([page_id | rest], acc) do
    with {:ok, page} <- get_json("/pages/#{page_id}"),
         {:ok, body} <- fetch_page_body(page_id) do
      fetch_pages_by_ids(rest, [normalize_page(page, body) | acc])
    end
  end

  defp fetch_page_body(page_id) do
    fetch_block_children(page_id, nil, [])
  end

  defp fetch_block_children(block_id, start_cursor, acc_blocks) do
    path = children_path(block_id, start_cursor)

    with {:ok, body} <- get_json(path),
         {:ok, blocks, next_cursor} <- decode_children_response(body) do
      updated_blocks = Enum.reverse(blocks, acc_blocks)

      case next_cursor do
        cursor when is_binary(cursor) ->
          fetch_block_children(block_id, cursor, updated_blocks)

        nil ->
          updated_blocks
          |> Enum.reverse()
          |> blocks_to_plain_text()
          |> then(&{:ok, &1})
      end
    end
  end

  defp children_path(block_id, nil), do: "/blocks/#{block_id}/children?page_size=100"
  defp children_path(block_id, cursor), do: "/blocks/#{block_id}/children?page_size=100&start_cursor=#{URI.encode(cursor)}"

  defp query_payload(states, require_run_agent?, start_cursor) do
    %{
      "page_size" => @page_size,
      "filter" => query_filter(states, require_run_agent?),
      "sorts" => [
        %{
          "timestamp" => "created_time",
          "direction" => "ascending"
        }
      ]
    }
    |> maybe_put_start_cursor(start_cursor)
  end

  defp maybe_put_start_cursor(payload, cursor) when is_binary(cursor), do: Map.put(payload, "start_cursor", cursor)
  defp maybe_put_start_cursor(payload, _cursor), do: payload

  defp query_filter(states, require_run_agent?) do
    state_filter = %{
      "or" =>
        states
        |> Enum.map(&String.trim(to_string(&1)))
        |> Enum.reject(&(&1 == ""))
        |> Enum.map(fn state ->
          %{"property" => "Status", "select" => %{"equals" => state}}
        end)
    }

    if require_run_agent? do
      %{
        "and" => [
          state_filter,
          %{"property" => "Run Agent", "checkbox" => %{"equals" => true}}
        ]
      }
    else
      state_filter
    end
  end

  defp decode_query_response(%{"results" => pages} = body) when is_list(pages) do
    {:ok, pages, next_cursor(body)}
  end

  defp decode_query_response(%{"object" => "error"} = body), do: {:error, {:notion_api_error, body}}
  defp decode_query_response(_unknown), do: {:error, :notion_unknown_query_payload}

  defp decode_children_response(%{"results" => blocks} = body) when is_list(blocks) do
    {:ok, blocks, next_cursor(body)}
  end

  defp decode_children_response(%{"object" => "error"} = body), do: {:error, {:notion_api_error, body}}
  defp decode_children_response(_unknown), do: {:error, :notion_unknown_children_payload}

  defp next_cursor(%{"has_more" => true, "next_cursor" => cursor}) when is_binary(cursor), do: cursor
  defp next_cursor(_body), do: nil

  defp normalize_page(page, body) when is_map(page) do
    properties = Map.get(page, "properties", %{})

    %Issue{
      id: page["id"],
      identifier: page_identifier(page),
      title: title_property(properties["Name"]),
      description: body,
      priority: priority_property(properties["Priority"]),
      state: select_property(properties["Status"]),
      branch_name: rich_text_property(properties["Branch"]),
      url: page["url"],
      assignee_id: nil,
      blocked_by: [],
      labels: labels(properties),
      assigned_to_worker: checkbox_property(properties["Run Agent"]),
      created_at: parse_datetime(page["created_time"]),
      updated_at: parse_datetime(page["last_edited_time"])
    }
  end

  defp page_identifier(%{"id" => id}) when is_binary(id) do
    "NOTION-" <> String.slice(String.replace(id, "-", ""), 0, 8)
  end

  defp page_identifier(_page), do: "NOTION-UNKNOWN"

  defp labels(properties) do
    properties
    |> Map.get("Repo")
    |> select_property()
    |> case do
      repo when is_binary(repo) and repo != "" -> [String.downcase(repo)]
      _ -> []
    end
  end

  defp title_property(%{"title" => rich_text}), do: rich_text_plain(rich_text)
  defp title_property(_property), do: nil

  defp rich_text_property(%{"rich_text" => rich_text}), do: rich_text_plain(rich_text)
  defp rich_text_property(_property), do: nil

  defp select_property(%{"select" => %{"name" => name}}) when is_binary(name), do: name
  defp select_property(_property), do: nil

  defp checkbox_property(%{"checkbox" => checked}) when is_boolean(checked), do: checked
  defp checkbox_property(_property), do: false

  defp priority_property(%{"select" => %{"name" => "High"}}), do: 1
  defp priority_property(%{"select" => %{"name" => "Medium"}}), do: 3
  defp priority_property(%{"select" => %{"name" => "Low"}}), do: 4
  defp priority_property(_property), do: nil

  defp blocks_to_plain_text(blocks) do
    blocks
    |> Enum.map(&block_to_plain_text/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp block_to_plain_text(%{"type" => type} = block) when is_binary(type) do
    block
    |> get_in([type, "rich_text"])
    |> rich_text_plain()
    |> String.trim()
  end

  defp block_to_plain_text(_block), do: ""

  defp rich_text_plain(rich_text) when is_list(rich_text) do
    Enum.map_join(rich_text, "", fn
      %{"plain_text" => text} when is_binary(text) -> text
      %{"text" => %{"content" => text}} when is_binary(text) -> text
      _ -> ""
    end)
  end

  defp rich_text_plain(_rich_text), do: ""

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp build_update_properties(fields) do
    properties =
      fields
      |> Enum.reduce(%{}, fn {key, value}, acc ->
        put_update_property(acc, normalize_field_name(key), value)
      end)
      |> Enum.reject(fn {_property, value} -> is_nil(value) end)
      |> Map.new()

    if map_size(properties) == 0 do
      {:error, :empty_notion_update}
    else
      {:ok, properties}
    end
  end

  defp normalize_field_name(field) when is_atom(field), do: field |> Atom.to_string() |> normalize_field_name()

  defp normalize_field_name(field) when is_binary(field) do
    field
    |> String.downcase()
    |> String.replace(~r/[\s-]+/, "_")
  end

  defp normalize_field_name(field), do: to_string(field)

  defp put_update_property(acc, "status", value), do: maybe_put_select(acc, "Status", value)
  defp put_update_property(acc, "branch", value), do: maybe_put_rich_text(acc, "Branch", value)
  defp put_update_property(acc, "pr_url", value), do: maybe_put_url(acc, "PR URL", value)
  defp put_update_property(acc, "agent_summary", value), do: maybe_put_rich_text(acc, "Agent Summary", value)
  defp put_update_property(acc, "error", value), do: maybe_put_rich_text(acc, "Error", value)
  defp put_update_property(acc, "run_agent", value), do: maybe_put_checkbox(acc, "Run Agent", value)
  defp put_update_property(acc, "last_run_at", value), do: maybe_put_date(acc, "Last Run At", value)
  defp put_update_property(acc, _field, _value), do: acc

  defp maybe_put_select(acc, _property, value) when value in [nil, ""], do: acc
  defp maybe_put_select(acc, property, value), do: Map.put(acc, property, %{"select" => %{"name" => to_string(value)}})

  defp maybe_put_rich_text(acc, property, value) when is_binary(value) do
    Map.put(acc, property, %{"rich_text" => [%{"type" => "text", "text" => %{"content" => truncate_text(value)}}]})
  end

  defp maybe_put_rich_text(acc, _property, _value), do: acc

  defp maybe_put_url(acc, _property, value) when value in [nil, ""], do: acc
  defp maybe_put_url(acc, property, value) when is_binary(value), do: Map.put(acc, property, %{"url" => value})
  defp maybe_put_url(acc, _property, _value), do: acc

  defp maybe_put_checkbox(acc, property, value) when is_boolean(value), do: Map.put(acc, property, %{"checkbox" => value})
  defp maybe_put_checkbox(acc, _property, _value), do: acc

  defp maybe_put_date(acc, property, %DateTime{} = value) do
    Map.put(acc, property, %{"date" => %{"start" => DateTime.to_iso8601(value)}})
  end

  defp maybe_put_date(acc, property, value) when is_binary(value) and value != "" do
    Map.put(acc, property, %{"date" => %{"start" => value}})
  end

  defp maybe_put_date(acc, _property, _value), do: acc

  defp truncate_text(value) when byte_size(value) <= 2_000, do: value
  defp truncate_text(value), do: String.slice(value, 0, 1_997) <> "..."

  defp comment_blocks(body) do
    body
    |> chunk_text(1_900)
    |> Enum.map(fn chunk ->
      %{
        "object" => "block",
        "type" => "paragraph",
        "paragraph" => %{
          "rich_text" => [
            %{
              "type" => "text",
              "text" => %{"content" => chunk}
            }
          ]
        }
      }
    end)
  end

  defp chunk_text(value, max_size) do
    value
    |> String.graphemes()
    |> Enum.chunk_every(max_size)
    |> Enum.map(&Enum.join/1)
  end

  defp get_json(path), do: request(:get, path, nil)
  defp post_json(path, payload), do: request(:post, path, payload)
  defp patch_json(path, payload), do: request(:patch, path, payload)

  defp request(method, path, payload) do
    url = notion_url(path)
    opts = [headers: notion_headers(), connect_options: [timeout: 30_000]]
    opts = if is_nil(payload), do: opts, else: Keyword.put(opts, :json, payload)

    case Req.request([method: method, url: url] ++ opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, response} ->
        Logger.error("Notion request failed status=#{response.status} body=#{summarize_error_body(response.body)}")
        {:error, {:notion_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Notion request failed: #{inspect(reason)}")
        {:error, {:notion_api_request, reason}}
    end
  end

  defp notion_url(path) do
    Config.settings!().tracker.endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp notion_headers do
    [
      {"Authorization", "Bearer #{Config.settings!().tracker.api_key}"},
      {"Notion-Version", @notion_version},
      {"Content-Type", "application/json"}
    ]
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
