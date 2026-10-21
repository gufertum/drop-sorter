# Automation

Drop Sorter can be driven from the terminal, by AI agents and over HTTP. All three use the same engine,
configuration, learning and undo as the app, and none of them can change the configuration.

## Command line

`dropsorter` works with or without the app running. Install it with **Settings › Advanced › Install
Command Line Tool** (links it into `~/.local/bin`), or:

```bash
ln -sf "/Applications/Drop Sorter.app/Contents/Helpers/dropsorter" ~/.local/bin/dropsorter
```

| Command | Does |
|---|---|
| `dropsorter folders [-q FILTER]` | list the folders, filtered like the chooser |
| `dropsorter suggest NAME\|PATH…` | suggest a folder, with score and reasons |
| `dropsorter move (--to FOLDER \| --auto) PATH…` | move into FOLDER, or into the clear suggestion |
| `dropsorter copy (--to FOLDER \| --auto) PATH…` | the same, but copy |
| `dropsorter undo [--id ID]` | undo the most recent operation, once |
| `dropsorter last` | show what undo would revert |
| `dropsorter config` | show the configuration in use |
| `dropsorter drop-apps` | list the drop apps |
| `dropsorter mcp` | MCP server for AI agents |
| `dropsorter serve [--port N]` | REST API without the app |
| `dropsorter --version` | the version |

Options: `--json` (machine-readable output), `--dry-run` (show the new names, change nothing),
`--skip-identical` (leave files whose content is already in the target folder),
`--also-copy-to FOLDER` (a plain copy into a second folder), `--limit N` (suggest: number of candidates).

```bash
dropsorter folders -q "fin inv"
dropsorter suggest ~/Downloads/invoice-hetzner.pdf
dropsorter move --auto ~/Downloads/invoice-hetzner.pdf
dropsorter copy --to "Files/80 Backup" ~/Desktop/contract.pdf
dropsorter move --dry-run --to "Files/90 Archive" ~/Downloads/*.pdf
dropsorter undo
```

**FOLDER** is a short name as `dropsorter folders` prints it (the target folder's name and the path
inside it, such as `Files/30 Areas/Finance`) or a full path. It must be one of your target folders or
a folder inside one.

**Exit status**: 0 ok, 1 some items failed, 2 usage or input error, 3 configuration error, 4 no clear
suggestion (`--auto`), 5 nothing to undo. With `--json`, errors come as
`{"error": {"code": "…", "message": "…"}}`. `DROPSORTER_LOG=1` shows the engine's log lines.

## MCP for AI agents

`dropsorter mcp` is a [Model Context Protocol](https://modelcontextprotocol.io) server over stdio.
An agent can list folders, ask for suggestions, sort files and undo.

| Tool | Does |
|---|---|
| `list_folders` | the folders, optionally filtered |
| `suggest_folder` | ranked suggestions for names or paths |
| `sort_files` | move or copy into a folder or the clear suggestion; `dry_run`, `identical`, `also_copy_to` |
| `undo_last` | undo the most recent operation |
| `last_operation` | what undo would revert |
| `get_config` | read the configuration |
| `list_drop_apps` | the drop apps and their state |

Claude Code:

```bash
claude mcp add drop-sorter -- ~/.local/bin/dropsorter mcp
```

Other clients:

```json
{"mcpServers": {"drop-sorter": {"command": "/Applications/Drop Sorter.app/Contents/Helpers/dropsorter", "args": ["mcp"]}}}
```

Errors come back as tool errors with a code, such as `nothing_to_undo`, so the agent can react.

## REST API

Off by default. Turn it on in **Settings › Advanced › API**, choose the port (default 47800) and click
**Copy Token**. Without the app: `dropsorter serve`.

```bash
TOKEN=$(cat ~/Library/Application\ Support/li.sudo.dropsorter/api-token)
curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:47800/v1/folders?q=inv"
curl -s -H "Authorization: Bearer $TOKEN" -d '{"paths":["/Users/me/Downloads/invoice.pdf"],"auto":true}' http://127.0.0.1:47800/v1/sort
curl -s -H "Authorization: Bearer $TOKEN" -X POST http://127.0.0.1:47800/v1/undo
```

| Route | Body | Result |
|---|---|---|
| `GET /v1/health` | | `{status, version}`, no token needed |
| `GET /v1/folders?q=` | | `{targets, folders}` |
| `POST /v1/suggest` | `{names, limit?}` | `{preselected, candidates}` |
| `POST /v1/sort` | `{paths, folder? or auto?, mode?, identical?, alsoCopyTo?, dryRun?}` | `{id, mode, folder, path, dryRun, items, skipped, failed, extraCopies, extraSkipped, extraFailed}` |
| `POST /v1/undo` | `{id?}` | `{id, mode, folder, items, failed}` |
| `GET /v1/last` | | `{operation}`, null when there is nothing to undo |
| `GET /v1/config` | | the configuration |
| `GET /v1/drop-apps` | | `{dropApps}` |

Errors: `{"error": {"code", "message"}}` with 400 `invalid_input`, 401 `unauthorized`, 404
`not_found` or `no_route`, 405 `method_not_allowed`, 409 `nothing_to_undo` or `stale_undo`, 413, 421
`bad_host`, 422 `folder_not_allowed` or `no_clear_suggestion`, 503 `config_error` or
`no_target_folders`.

### Security

- The API listens on `127.0.0.1` only: no other computer can reach it.
- Every route except health needs `Authorization: Bearer <token>`. The token is 64 random hex characters
  in `api-token` in the support folder, readable only by you. **New Token** replaces it; the old one
  stops working at once.
- Only `127.0.0.1` and `localhost` are accepted as Host, so a web page in your browser cannot reach the
  API through a name it controls.
- Request size is limited, and no route can change the configuration.

Moves through the API show the usual toast with Undo while the app runs.
