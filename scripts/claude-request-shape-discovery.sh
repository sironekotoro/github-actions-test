#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CANDIDATE="${1:-$ROOT}"
[ -f "$CANDIDATE/docker/review-repair-agent.Dockerfile" ] || { echo "CLAUDE_B3A_INVALID_CANDIDATE: missing pinned agent Dockerfile" >&2; exit 1; }

suffix="${GITHUB_RUN_ID:-$$}-${RANDOM}"
agent_image="claude-b3a-agent:${suffix}"
network="claude-b3a-${suffix}"
mock_name="claude-b3a-mock-${suffix}"
probe_name="claude-b3a-probe-${suffix}"
tmpdir="$(mktemp -d)"
mock_script="$tmpdir/mock.mjs"
workspace="$tmpdir/workspace"
mkdir -p "$workspace"
printf 'B3a local Claude request-shape discovery workspace.\n' > "$workspace/README.txt"

cleanup() {
  docker rm -f "$probe_name" "$mock_name" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker image rm -f "$agent_image" >/dev/null 2>&1 || true
  rm -rf "$tmpdir"
}
trap cleanup EXIT

echo "Building pinned Agent Dispatch image from trusted checkout..."
docker build --tag "$agent_image" --file "$CANDIDATE/docker/review-repair-agent.Dockerfile" "$CANDIDATE" >/dev/null

claude_version="$(docker run --rm --network none --read-only --cap-drop=ALL --security-opt=no-new-privileges "$agent_image" claude --version 2>&1)"
printf 'Pinned Claude Code CLI: %s\n' "$claude_version"
case "$claude_version" in
  *2.1.165*) ;;
  *) echo "CLAUDE_B3A_VERSION_MISMATCH: expected pinned Claude Code 2.1.165" >&2; exit 1 ;;
esac

cat > "$mock_script" <<'NODE'
import http from "node:http";
const expectedCapability = "b3a-local-capability";
const safeHeader = (req, name) => req.headers[name] ?? null;

function summarizeBody(raw) {
  let parsed = null;
  let parseOk = false;
  try {
    parsed = JSON.parse(raw.toString("utf8"));
    parseOk = true;
  } catch {}
  const toolNames = Array.isArray(parsed?.tools)
    ? parsed.tools.map((tool) => tool?.name ?? tool?.type ?? null).filter(Boolean)
    : [];
  const messageRoles = Array.isArray(parsed?.messages)
    ? parsed.messages.map((message) => message?.role ?? null)
    : [];
  return {
    rawBytes: raw.length,
    parseOk,
    bodyKeys: parsed && typeof parsed === "object" && !Array.isArray(parsed) ? Object.keys(parsed).sort() : [],
    model: parsed?.model ?? null,
    maxTokens: parsed?.max_tokens ?? null,
    stream: parsed?.stream ?? null,
    thinkingType: parsed?.thinking?.type ?? null,
    outputEffort: parsed?.output_config?.effort ?? null,
    toolCount: toolNames.length,
    toolNames: toolNames.slice(0, 40),
    messageRoles,
    systemShape: Array.isArray(parsed?.system) ? "array" : typeof parsed?.system,
  };
}

const server = http.createServer(async (req, res) => {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks);
  const url = new URL(req.url, "http://mock");
  const xApiKey = safeHeader(req, "x-api-key");
  const authorization = safeHeader(req, "authorization");
  const capture = {
    method: req.method,
    path: url.pathname,
    query: url.search,
    xApiKeyMatchesCapability: xApiKey === expectedCapability,
    authorizationScheme: authorization?.split(" ", 1)[0] ?? null,
    authorizationMatchesCapability: authorization === `Bearer ${expectedCapability}`,
    anthropicVersion: safeHeader(req, "anthropic-version"),
    anthropicBeta: safeHeader(req, "anthropic-beta"),
    contentType: safeHeader(req, "content-type"),
    accept: safeHeader(req, "accept"),
    userAgent: safeHeader(req, "user-agent"),
    ...summarizeBody(raw),
  };
  process.stdout.write(`CAPTURE ${JSON.stringify(capture)}\n`);

  if (req.method === "GET" && url.pathname === "/healthz") {
    res.writeHead(200, {"content-type": "text/plain"});
    res.end("ok");
    return;
  }

  if (req.method === "POST" && url.pathname === "/v1/messages") {
    const body = (() => { try { return JSON.parse(raw.toString("utf8")); } catch { return {}; } })();
    if (body.stream === true) {
      const message = {
        id: "msg_b3a",
        type: "message",
        role: "assistant",
        model: body.model ?? "b3a-requested-model-marker",
        content: [],
        stop_reason: null,
        stop_sequence: null,
        usage: {input_tokens: 0, output_tokens: 0},
      };
      res.writeHead(200, {"content-type": "text/event-stream", "cache-control": "no-cache", connection: "close"});
      res.end(
        `event: message_start\ndata: ${JSON.stringify({type: "message_start", message})}\n\n` +
        `event: content_block_start\ndata: ${JSON.stringify({type: "content_block_start", index: 0, content_block: {type: "text", text: ""}})}\n\n` +
        `event: content_block_delta\ndata: ${JSON.stringify({type: "content_block_delta", index: 0, delta: {type: "text_delta", text: "B3A_OK"}})}\n\n` +
        `event: content_block_stop\ndata: ${JSON.stringify({type: "content_block_stop", index: 0})}\n\n` +
        `event: message_delta\ndata: ${JSON.stringify({type: "message_delta", delta: {stop_reason: "end_turn", stop_sequence: null}, usage: {output_tokens: 1}})}\n\n` +
        `event: message_stop\ndata: ${JSON.stringify({type: "message_stop"})}\n\n`
      );
      return;
    }

    res.writeHead(200, {"content-type": "application/json"});
    res.end(JSON.stringify({
      id: "msg_b3a",
      type: "message",
      role: "assistant",
      model: body.model ?? "b3a-requested-model-marker",
      content: [{type: "text", text: "B3A_OK"}],
      stop_reason: "end_turn",
      stop_sequence: null,
      usage: {input_tokens: 0, output_tokens: 1},
    }));
    return;
  }

  res.writeHead(404, {"content-type": "application/json"});
  res.end(JSON.stringify({type: "error", error: {type: "not_found_error", message: "local discovery mock: unsupported route"}}));
});
server.listen(8080, "0.0.0.0", () => process.stdout.write("MOCK_READY\n"));
NODE

docker network create --internal "$network" >/dev/null
docker run -d --name "$mock_name" --network "$network" --network-alias mock \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=16m \
  --mount "type=bind,src=$mock_script,dst=/runtime/mock.mjs,readonly" \
  "$agent_image" node /runtime/mock.mjs >/dev/null

mock_ready=false
for _ in $(seq 1 50); do
  if docker logs "$mock_name" 2>&1 | grep -q '^MOCK_READY$'; then mock_ready=true; break; fi
  sleep 0.1
done
[ "$mock_ready" = true ] || { echo "CLAUDE_B3A_MOCK_START_FAILED" >&2; docker logs "$mock_name" >&2 || true; exit 1; }

set +e
docker run --name "$probe_name" --network "$network" \
  --read-only --cap-drop=ALL --security-opt=no-new-privileges \
  --tmpfs /runtime:rw,nosuid,nodev,size=128m \
  --tmpfs /tmp:rw,nosuid,nodev,size=128m \
  --mount "type=bind,src=$workspace,dst=/workspace" --workdir /workspace \
  --env HOME=/runtime/home \
  --env ANTHROPIC_API_KEY=b3a-local-capability \
  --env ANTHROPIC_BASE_URL=http://mock:8080 \
  --env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  --env DISABLE_TELEMETRY=1 \
  --env DISABLE_ERROR_REPORTING=1 \
  --env DISABLE_AUTOUPDATER=1 \
  "$agent_image" claude -p "Return exactly B3A_OK without invoking tools, then finish." \
    --model b3a-requested-model-marker \
    --dangerously-skip-permissions
probe_status=$?
set -e

probe_logs="$(docker logs "$probe_name" 2>&1 || true)"
mock_logs="$(docker logs "$mock_name" 2>&1 || true)"
printf '%s\n' "$mock_logs" | grep '^CAPTURE ' || true

if [ "$probe_status" -ne 0 ]; then
  echo "CLAUDE_B3A_PROBE_FAILED: pinned CLI exited $probe_status" >&2
  printf '%s\n' "$probe_logs" >&2
  exit "$probe_status"
fi

capture_count="$(printf '%s\n' "$mock_logs" | grep -c '^CAPTURE ' || true)"
[ "$capture_count" -ge 1 ] || { echo "CLAUDE_B3A_NO_REQUEST_CAPTURED" >&2; exit 1; }

messages_count="$(printf '%s\n' "$mock_logs" | grep '^CAPTURE ' | grep -c '\"method\":\"POST\",\"path\":\"/v1/messages\"' || true)"
[ "$messages_count" -ge 1 ] || { echo "CLAUDE_B3A_MESSAGES_NOT_OBSERVED" >&2; exit 1; }

printf '%s\n' "$mock_logs" | grep '^CAPTURE ' | grep '\"method\":\"POST\",\"path\":\"/v1/messages\"' | grep -q '\"xApiKeyMatchesCapability\":true\|\"authorizationMatchesCapability\":true' || {
  echo "CLAUDE_B3A_AUTH_SHAPE_MISMATCH" >&2
  exit 1
}

printf '%s\n' "$mock_logs" | grep '^CAPTURE ' | grep '\"method\":\"POST\",\"path\":\"/v1/messages\"' | grep -q '\"model\":\"b3a-requested-model-marker\"' || {
  echo "CLAUDE_B3A_MODEL_BINDING_MISMATCH" >&2
  exit 1
}

echo "CLAUDE_B3A_DISCOVERY=PASS"
echo "CLAUDE_B3A_CAPTURE_COUNT=$capture_count"
echo "CLAUDE_B3A_MESSAGES_COUNT=$messages_count"
echo "CLAUDE_B3A_PROVIDER_INFERENCE=0"
