# Adding integrations

OpenAvatar's action layer has three tiers behind one protocol. The design goal: growing to hundreds or thousands of integrations without touching Swift.

| Tier | What it is | Effort to add one |
|---|---|---|
| Native plugins | GitHub, Slack, Linear, Email — hand-written for deep behavior (local git workdirs, SMTP, undo semantics) | Swift code |
| **Manifests** | A JSON file describing auth + tools + HTTP templates, interpreted by a generic engine | **One JSON file, no rebuild** |
| **MCP servers** | Any [Model Context Protocol](https://modelcontextprotocol.io) server; its tools are discovered at runtime | **One command line in Settings** |

Every tier goes through the same trust matrix, approval UI, 🤖 attribution, metrics, and undo plumbing.

## Manifest integrations

Drop a `.json` file into `~/Library/Application Support/OpenAvatar/integrations/` (Settings → Integrations → "Open manifests folder"). It appears in Settings with a credential field, in the trust matrix, and in the planner's tool catalog immediately.

```json
{
  "id": "todoist",
  "name": "Todoist",
  "baseURL": "https://api.todoist.com/rest/v2",
  "auth": { "kind": "bearer", "hint": "Todoist API token" },
  "healthCheck": { "method": "GET", "path": "/projects" },
  "tools": [
    {
      "name": "create_task",
      "description": "Create a Todoist task.",
      "riskClass": "write",
      "parameters": {
        "type": "object",
        "properties": {
          "content": { "type": "string", "description": "task title" },
          "due_string": { "type": "string" }
        },
        "required": ["content"]
      },
      "attributedParams": ["content"],
      "request": {
        "method": "POST",
        "path": "/tasks",
        "body": { "content": "{{content}}", "due_string": "{{due_string}}" }
      },
      "response": {
        "summaryTemplate": "Created Todoist task: {{content}}",
        "urlPath": "/url",
        "revertHandle": { "task_id": "/id" }
      },
      "revert": { "method": "DELETE", "path": "/tasks/{{revert.task_id}}" }
    }
  ]
}
```

### Reference

- **`auth.kind`**: `bearer` (Authorization: Bearer …), `header` (custom header via `name`), `query` (query param via `name`), `none`. Optional `valuePrefix` (e.g. `"Token "`). Credentials are stored in the macOS Keychain, keyed by manifest `id`.
- **`tools[].parameters`**: standard JSON Schema — this is what the planner LLM sees.
- **`tools[].riskClass`**: `read` | `draft` | `write` | `destructive`. Destructive tools obey graduated autonomy (10 clean approvals before Autonomous unlocks). Undeclared tools default to destructive.
- **Templates**: `{{param}}` substitutes tool arguments in `path`, `query`, `body`, and `summaryTemplate`. A body value that is *exactly* `"{{param}}"` keeps the argument's JSON type (numbers stay numbers); unresolved optional params are dropped from the body. `{{response./json/pointer}}` reads the response; `{{revert.key}}` reads the revert handle in `revert` requests.
- **`attributedParams`**: which string params receive the 🤖 prefix. If omitted, the engine prefixes the conventional set (`text`, `body`, `message`, `title`, `content`, `comment`). Attribution is enforced by the engine — manifests choose *where*, never *whether*.
- **`revert`** + **`response.revertHandle`**: enables one-click Undo. Omit for irreversible actions.

Two starter manifests (Todoist, Notion) ship built-in as working examples; a user file with the same `id` overrides the built-in.

## MCP servers

Settings → Integrations → MCP servers → add a name and launch command, e.g.:

```
name:    notion
command: npx -y @notionhq/notion-mcp-server
```

OpenAvatar speaks JSON-RPC over stdio (`initialize` → `tools/list` → `tools/call`), so the server's entire tool catalog becomes available to the planner, namespaced as `mcp-<name>.<tool>` in the trust matrix. Notes:

- Servers inherit your shell environment (launched via `zsh -lc`), so env-var-based auth (e.g. `NOTION_TOKEN`) works the standard MCP way.
- MCP tools carry no risk metadata, so everything defaults to `write` (Ask-first), and destructive-sounding names (`delete_*`, `send_*`, `merge_*`, `publish_*`, `deploy_*`, `remove_*`, `drop_*`) are escalated to `destructive`.
- 🤖 attribution is applied to the conventional text-bearing parameters.
- Connections persist for the app's lifetime; health check = successful `tools/list`.

## Which tier to pick

- REST API with token auth → **manifest** (minutes of work).
- The service already has an MCP server → **MCP** (seconds of work).
- Needs local state, multi-step protocols, or custom undo semantics → native plugin.
