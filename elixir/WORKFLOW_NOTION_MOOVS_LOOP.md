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
    git clone git@github.com:swoopapp/moovs-loop.git .
    cd loop-portal && npm install
agent:
  max_concurrent_agents: 1
  max_turns: 8
codex:
  command: codex --config shell_environment_policy.inherit=all app-server
  approval_policy: never
  thread_sandbox: workspace-write
---

You are working on a Moovs Loop Notion queue task.

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

1. Immediately call `notion_task_update` for `{{ issue.id }}` with `status: "Running"` and a short `comment` saying you started the Moovs Loop task.
2. Work only inside the provided `moovs-loop` repository copy.
3. Treat `loop-portal/` as the application root unless the task explicitly points elsewhere.
4. If this is an inspection, research, or smoke-test task, make no code changes unless the task explicitly asks for them.
5. For implementation tasks:
   - Create a focused branch from the current default branch.
   - Read the relevant code and docs before editing.
   - Keep changes scoped to the task.
   - Do not commit secrets, local env files, generated auth links, or local credential artifacts.
   - Commit, push, and open a draft pull request when possible.
6. Preserve existing local/user changes. If the workspace contains unexpected changes, inspect them and work with them instead of reverting them.
7. Use `cd loop-portal` for app commands. Default validation for code changes is:
   - `npm run lint`
   - `npm run build`
8. For UI changes, validate the affected operator-facing path in the running app when possible:
   - Start the app with `npm run dev:full`.
   - Use `http://localhost:5173/` for the frontend.
   - Use `http://127.0.0.1:3001/api/health` for API health.
   - Check desktop and mobile-sized layouts when browser tools are available.
9. For backend, Notion, Postgres, S3 attachment, Slack, or email notification changes, run the most relevant local proof available. If required secrets or services are missing, document exactly what could not be exercised and why.
10. Respect Moovs Loop product constraints:
    - The portal is an operator-facing support and roadmap tool, not a marketing site.
    - Keep UI changes quiet, task-focused, responsive, and consistent with existing components.
    - Keep Notion as the source of truth for ticket metadata unless the task explicitly changes that architecture.
    - Keep Postgres-owned state isolated to Loop-specific local/cache/event/attachment data.
11. When finished, call `notion_task_update` for `{{ issue.id }}` with:
    - `status: "Done"` if completed, or `status: "Blocked"` / `status: "Failed"` if not.
    - `agent_summary` describing the result and validation.
    - `branch` and `pr_url` when those exist.
    - `run_agent: false`.
12. Do not ask a human for follow-up unless a required permission, secret, or external system is unavailable.
