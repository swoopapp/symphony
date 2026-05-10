defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Linear.Client, Notion}

  @linear_graphql_tool "linear_graphql"
  @notion_task_update_tool "notion_task_update"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @notion_task_update_description """
  Update the current Notion queue task using Symphony's configured Notion auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }
  @notion_task_update_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["page_id"],
    "properties" => %{
      "page_id" => %{
        "type" => "string",
        "description" => "Notion page ID for the queue task."
      },
      "status" => %{
        "type" => ["string", "null"],
        "description" => "Optional Status select value, for example Running, Done, Failed, or Blocked."
      },
      "branch" => %{
        "type" => ["string", "null"],
        "description" => "Optional git branch name to write to the Branch property."
      },
      "pr_url" => %{
        "type" => ["string", "null"],
        "description" => "Optional pull request URL to write to the PR URL property."
      },
      "agent_summary" => %{
        "type" => ["string", "null"],
        "description" => "Optional final summary to write to the Agent Summary property."
      },
      "error" => %{
        "type" => ["string", "null"],
        "description" => "Optional error or blocker details to write to the Error property."
      },
      "run_agent" => %{
        "type" => ["boolean", "null"],
        "description" => "Optional Run Agent checkbox value."
      },
      "comment" => %{
        "type" => ["string", "null"],
        "description" => "Optional note to append to the task page body."
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @notion_task_update_tool ->
        execute_notion_task_update(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @linear_graphql_tool,
        "description" => @linear_graphql_description,
        "inputSchema" => @linear_graphql_input_schema
      },
      %{
        "name" => @notion_task_update_tool,
        "description" => @notion_task_update_description,
        "inputSchema" => @notion_task_update_input_schema
      }
    ]
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp execute_notion_task_update(arguments, opts) do
    notion_client = Keyword.get(opts, :notion_client, Notion.Client)

    with {:ok, page_id, fields, comment} <- normalize_notion_task_update_arguments(arguments),
         :ok <- maybe_update_notion_page(notion_client, page_id, fields),
         :ok <- maybe_append_notion_comment(notion_client, page_id, comment) do
      dynamic_tool_response(
        true,
        encode_payload(%{
          "ok" => true,
          "page_id" => page_id,
          "updated_fields" => Map.keys(fields)
        })
      )
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp normalize_notion_task_update_arguments(arguments) when is_map(arguments) do
    case Map.get(arguments, "page_id") || Map.get(arguments, :page_id) do
      page_id when is_binary(page_id) ->
        fields = notion_update_fields(arguments)
        comment = Map.get(arguments, "comment") || Map.get(arguments, :comment)

        cond do
          String.trim(page_id) == "" ->
            {:error, :missing_notion_page_id}

          map_size(fields) == 0 and blank_comment?(comment) ->
            {:error, :empty_notion_update}

          true ->
            {:ok, page_id, fields, comment}
        end

      _ ->
        {:error, :missing_notion_page_id}
    end
  end

  defp normalize_notion_task_update_arguments(_arguments), do: {:error, :invalid_notion_update_arguments}

  defp notion_update_fields(arguments) do
    Enum.reduce(
      ["status", "branch", "pr_url", "agent_summary", "error", "run_agent"],
      %{},
      fn field, acc ->
        case Map.fetch(arguments, field) do
          {:ok, value} -> Map.put(acc, field, value)
          :error -> fetch_atom_field(arguments, field, acc)
        end
      end
    )
  end

  defp fetch_atom_field(arguments, field, acc) do
    atom_field = String.to_existing_atom(field)

    case Map.fetch(arguments, atom_field) do
      {:ok, value} -> Map.put(acc, field, value)
      :error -> acc
    end
  rescue
    ArgumentError -> acc
  end

  defp maybe_update_notion_page(_notion_client, _page_id, fields) when map_size(fields) == 0, do: :ok

  defp maybe_update_notion_page(notion_client, page_id, fields) do
    notion_client.update_page_properties(page_id, Map.put(fields, "last_run_at", DateTime.utc_now()))
  end

  defp maybe_append_notion_comment(_notion_client, _page_id, comment) when comment in [nil, ""], do: :ok

  defp maybe_append_notion_comment(notion_client, page_id, comment) when is_binary(comment) do
    notion_client.append_comment(page_id, comment)
  end

  defp maybe_append_notion_comment(_notion_client, _page_id, _comment), do: {:error, :invalid_notion_comment}

  defp blank_comment?(comment) when is_binary(comment), do: String.trim(comment) == ""
  defp blank_comment?(comment), do: comment in [nil, ""]

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_notion_page_id) do
    %{
      "error" => %{
        "message" => "`notion_task_update` requires a non-empty `page_id` string."
      }
    }
  end

  defp tool_error_payload(:invalid_notion_update_arguments) do
    %{
      "error" => %{
        "message" => "`notion_task_update` expects an object with `page_id` and at least one supported update field."
      }
    }
  end

  defp tool_error_payload(:empty_notion_update) do
    %{
      "error" => %{
        "message" => "`notion_task_update` requires at least one field or comment to update."
      }
    }
  end

  defp tool_error_payload(:invalid_notion_comment) do
    %{
      "error" => %{
        "message" => "`notion_task_update.comment` must be a string when provided."
      }
    }
  end

  defp tool_error_payload(:missing_notion_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Notion auth. Set `tracker.api_key` in `WORKFLOW.md` or export `NOTION_API_KEY`."
      }
    }
  end

  defp tool_error_payload(:missing_notion_database_id) do
    %{
      "error" => %{
        "message" => "Symphony is missing a Notion database ID. Set `tracker.database_id` in `WORKFLOW.md`."
      }
    }
  end

  defp tool_error_payload({:notion_api_status, status}) do
    %{
      "error" => %{
        "message" => "Notion API request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:notion_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Notion API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload({:notion_api_error, body}) do
    %{
      "error" => %{
        "message" => "Notion API returned an error payload.",
        "body" => body
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
