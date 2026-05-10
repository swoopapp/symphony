---
tracker:
  kind: notion
  database_id: "35c8aeaa-3759-8108-bc46-e5ff7aa67f8e"
  active_states:
    - Queued
    - Running
  terminal_states:
    - Done
    - Failed
    - Blocked
polling:
  interval_ms: 10000
workspace:
  root: ~/Dev/symphony-workspaces
hooks:
  after_create: |
    git clone git@github.com:swoopapp/moovs-contact-center.git .
agent:
  max_concurrent_agents: 1
  max_turns: 5
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
---

You are working on a Notion queue task.

Task page ID: {{ issue.id }}
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
URL: {{ issue.url }}
Labels: {{ issue.labels }}

Task body:
{% if issue.description %}
{{ issue.description }}
{% else %}
No task body provided.
{% endif %}

Instructions:

1. Immediately call `notion_task_update` for `{{ issue.id }}` with `status: "Running"` and a short `comment` saying you started.
2. Work only inside the provided repository copy.
3. If this is an inspection or smoke-test task, make no code changes unless the task explicitly asks for them.
4. For implementation tasks, create a focused branch, make the change, run relevant checks, commit, push, and open a draft pull request when possible.
5. When finished, call `notion_task_update` for `{{ issue.id }}` with:
   - `status: "Done"` if completed, or `status: "Blocked"` / `status: "Failed"` if not.
   - `agent_summary` describing the result.
   - `branch` and `pr_url` when those exist.
   - `run_agent: false`.
6. Do not ask a human for follow-up unless a required permission, secret, or external system is unavailable.
