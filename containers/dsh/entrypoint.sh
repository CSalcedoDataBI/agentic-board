#!/bin/sh
# agentic-board dsh sandbox entrypoint (#773). Every run of the image goes through here, so the
# upload switches and the refusals below hold even when someone runs the image by hand.
set -eu

refuse() { echo "abios-dsh: refusing to run: $*" >&2; exit 78; }

# dsh copies <cwd>/.env into its process environment (dsh-launch-environment). A worktree of a
# public repo is untrusted input, and a .env there could point DEEPSEEK_BASE_URL or a proxy at
# someone else's server and receive the API key. Variables set on the container outrank the file,
# but only for the names we thought of - so a workspace .env is refused outright (fail closed).
[ -e ./.env ] && refuse "the workspace has a .env file, which dsh would load into its environment."

# The session-log / telemetry switches. They are image ENV, re-checked here so a `docker run -e`
# that weakens them is refused rather than obeyed.
[ -n "${DSH_TELEMETRY_DISABLED:-}" ] || refuse "DSH_TELEMETRY_DISABLED is empty (telemetry opt-out)."
[ "${DSH_TELEMETRY_MODE:-}" = "DISABLED" ] || refuse "DSH_TELEMETRY_MODE is not DISABLED."
[ "${DEEPSEEK_BASE_URL:-}" = "https://api.deepseek.com/anthropic" ] || refuse "DEEPSEEK_BASE_URL is not the official endpoint."

# Permission mode: workspace-write (dsh's own sandbox: writes inside the workspace, approvals
# fail closed headless). Anything else is refused - the container is the outer sandbox, but the
# permission bypass stays an explicit opt-in that this image does not offer (#761).
[ "${DSH_PERMISSION_MODE:-}" = "workspace-write" ] || refuse "DSH_PERMISSION_MODE is not workspace-write."

# The model credential is the only secret this image expects. Any other token-shaped variable means
# the launch passed more of the host environment than it should have (#769) - refuse.
for name in $(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'); do
    case "$name" in
        DEEPSEEK_API_KEY) ;;
        *TOKEN*|*KEY*|*SECRET*|*PASSWORD*) refuse "unexpected credential-like variable '$name' in the environment." ;;
    esac
done

exec dsh --patch /opt/abios-dsh/no-upload.patch.yml "$@"
