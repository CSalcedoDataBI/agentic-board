# dsh sandbox image (pilot, #773)

The fleet's `dsh` adapter (DeepSeek Harness, `@deepseek-ai/dsh`) runs **only** inside this image.
`/board work -Fleet` never installs it, never pulls it and never runs `dsh` on the host: you build
the image once, and the fleet launches `docker run --rm` of it.

```sh
docker build -t agentic-board/dsh:0.2.0-rc.2 containers/dsh
```

Then set `DEEPSEEK_API_KEY` in your user environment. It is the only variable the container gets
from your machine.

This folder sits outside the plugin folder because the lockfile (about 370 KB) is over the plugin
directory's per-file limit.

## What is pinned

| Piece | Pin |
|---|---|
| Base image | `node:22.23.3-bookworm-slim` by tag **and** `sha256` digest. dsh needs Node >= 22.19.0. |
| dsh | `@deepseek-ai/dsh` `0.2.0-rc.2` exactly (`package.json`). Only pre-releases exist on npm. |
| Everything below it | `package-lock.json`, installed with `npm ci`: every package by version and integrity hash. |

No step fetches an unpinned version: no `@latest`, no `curl | sh`, no `apt-get`. The adapter runs
the image with `--pull=never`, so a missing image is reported, not downloaded.

## What the container gets

The launch line comes from `plugins/agentic-board/presets/adapters.json` (`dsh` entry):

- the worktree, bind-mounted at `/work`, as the only writable mount;
- a read-only root filesystem, plus `/tmp` as a tmpfs (512 MB). `DSH_HOME` is there, so dsh's
  session log, settings and anonymous id are discarded when the container exits;
- no host home folder and no Docker socket. It runs as the image's `node` user (uid 1000), with
  `--cap-drop=ALL` and `no-new-privileges`;
- `--cpus=2 --memory=2g --pids-limit=512`;
- one host variable, `DEEPSEEK_API_KEY`, passed by name so its value never appears in the launch
  script. There is no GitHub token, so dsh cannot push: it edits files and the host flow does the rest.

Network egress stays open, because dsh has to reach `api.deepseek.com`. Docker has no per-host
egress allow-list without an extra proxy, and this pilot does not add one.

## Uploads: off, and checked

`@deepseek-ai/dsh` 0.2.0-rc.2 ships two ways of sending data to DeepSeek besides the model call:

| dsh row | Default in 0.2.0-rc.2 | What it sends | Here |
|---|---|---|---|
| `session-log-deepseek` | on (`enabled: true`) | a `dsh_session_log` field with the canonical session log (prompts, tool calls, file contents, command output), inside every request to the official API | row disabled |
| `session-telemetry-otel` | `FEEDBACK_ONLY` | session records to `dsh-otel-collector.deepseeksvc.com` over OTLP | row disabled, `DSH_TELEMETRY_DISABLED=1`, `DSH_TELEMETRY_MODE=DISABLED`, collector URL `127.0.0.1:9`, and `--add-host` points both collector hosts at `127.0.0.1` |
| `plugin-package-inventory-deepseek` | on | the loaded plugin packages (name and version) | row disabled |

The session-log upload rides inside the same HTTPS request as the model call, so no network rule
can block it. Only the switch can. Hence these layers:

1. `no-upload.patch.yml` disables the three rows. `entrypoint.sh` always passes it with `--patch`,
   the last layer dsh applies.
2. The image build runs `dsh --dump-config` and **fails** unless all three rows show
   `disabled: true` (`check-upload-off.js`). An image with the upload on cannot be built.
3. `entrypoint.sh` refuses to start (exit 78) when:
   - the telemetry switches are weakened;
   - `DEEPSEEK_BASE_URL` is not the official endpoint;
   - the permission mode is not `workspace-write`;
   - the workspace has a `.env` file (dsh loads it into its environment, and a public repository's
     file could redirect the API key);
   - any other variable whose name contains `TOKEN`, `KEY`, `SECRET` or `PASSWORD` is set.

Per dsh's documentation, its API requests still carry a session id and an anonymous user id. Here
that id is random per run, because `DSH_HOME` is discarded with the container.

## Permissions

dsh's default mode, `workspace-write`, lets it edit inside its workspace (`/work`) and makes
approval requests fail closed when nobody can answer them, which is the case headless. The pilot
task ran to completion in this mode, so the adapter needs no permission bypass
(`requiresBypass: false`) and offers none.
