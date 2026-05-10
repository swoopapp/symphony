defmodule SymphonyElixir.NotionClientTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Notion.Client

  test "query payload filters by active status and run agent checkbox" do
    payload = Client.query_payload_for_test(["Queued", "Running"], require_run_agent?: true)

    assert payload["page_size"] == 25

    assert payload["filter"] == %{
             "and" => [
               %{
                 "or" => [
                   %{"property" => "Status", "select" => %{"equals" => "Queued"}},
                   %{"property" => "Status", "select" => %{"equals" => "Running"}}
                 ]
               },
               %{"property" => "Run Agent", "checkbox" => %{"equals" => true}}
             ]
           }
  end

  test "normalizes Notion pages into Symphony issues" do
    page = %{
      "id" => "35c8aeaa-3759-81d1-9b31-eed3bd79d0da",
      "url" => "https://www.notion.so/task",
      "created_time" => "2026-05-10T01:01:09.927Z",
      "last_edited_time" => "2026-05-10T01:02:09.927Z",
      "properties" => %{
        "Name" => %{
          "title" => [
            %{"plain_text" => "Smoke test: inspect repository"}
          ]
        },
        "Status" => %{"select" => %{"name" => "Queued"}},
        "Run Agent" => %{"checkbox" => true},
        "Repo" => %{"select" => %{"name" => "moovs-contact-center"}},
        "Priority" => %{"select" => %{"name" => "High"}},
        "Branch" => %{"rich_text" => [%{"plain_text" => "codex/notion-smoke"}]}
      }
    }

    issue = Client.normalize_page_for_test(page, "Task body")

    assert issue.id == "35c8aeaa-3759-81d1-9b31-eed3bd79d0da"
    assert issue.identifier == "NOTION-35c8aeaa"
    assert issue.title == "Smoke test: inspect repository"
    assert issue.description == "Task body"
    assert issue.state == "Queued"
    assert issue.assigned_to_worker
    assert issue.labels == ["moovs-contact-center"]
    assert issue.priority == 1
    assert issue.branch_name == "codex/notion-smoke"
    assert %DateTime{} = issue.created_at
    assert %DateTime{} = issue.updated_at
  end
end
