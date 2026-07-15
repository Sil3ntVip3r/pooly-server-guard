#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
assert_contains(){ [[ "$1" == *"$2"* ]] || fail "expected output to contain: $2"; }
assert_not_contains(){ [[ "$1" != *"$2"* ]] || fail "output unexpectedly contained secret text"; }

load_env(){ return 0; }
json_escape(){ python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
POOLY_GUARD_ENV="$TMP/server-guard.env"
POOLY_DISCORD_ENABLED=1
POOLY_DISCORD_WEBHOOK='https://discord.com/api/webhooks/123456789/TEST_SECRET_TOKEN_abcdef'
export POOLY_DISCORD_WEBHOOK

mkdir -p "$TMP/bin"
export FAKE_CURL_ARGS="$TMP/curl-args.txt"
export FAKE_CURL_STDIN="$TMP/curl-stdin.txt"
export FAKE_CURL_COUNT="$TMP/curl-count.txt"
export FAKE_CURL_SCENARIO=success

cat > "$TMP/bin/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
set -euo pipefail

count=0
[[ -r "$FAKE_CURL_COUNT" ]] && count="$(cat "$FAKE_CURL_COUNT")"
count=$((count+1))
printf '%s\n' "$count" > "$FAKE_CURL_COUNT"

{
  printf 'CALL %s\n' "$count"
  printf 'WEBHOOK_ENV=<%s>\n' "${POOLY_DISCORD_WEBHOOK-unset}"
  for arg in "$@"; do printf '<%s>\n' "$arg"; done
} >> "$FAKE_CURL_ARGS"

{
  printf 'CALL %s\n' "$count"
  cat
} >> "$FAKE_CURL_STDIN"

output_file=""
write_out=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    -o|--output)
      ((i+=1))
      output_file="${args[$i]:-}"
      ;;
    -w|--write-out)
      ((i+=1))
      write_out="${args[$i]:-}"
      ;;
  esac
done

code=204
body=''
if [[ "${FAKE_CURL_SCENARIO:-success}" == "retry" && "$count" == "1" ]]; then
  code=429
  body='{"retry_after":0.1}'
fi

if [[ -n "$output_file" ]]; then
  printf '%s' "$body" > "$output_file"
fi
if [[ -n "$write_out" ]]; then
  printf '%s' "$code"
fi
FAKE_CURL
chmod +x "$TMP/bin/curl"
PATH="$TMP/bin:$PATH"
export PATH

# shellcheck source=../lib/discord.sh
source "$ROOT/lib/discord.sh"

payload_file="$TMP/payload.json"
printf '%s\n' '{"content":"test"}' > "$payload_file"
chmod 600 "$payload_file"

out="$(discord_post_json_file "$payload_file")"
assert_contains "$out" "DISCORD RESULT: PASS"
args="$(cat "$FAKE_CURL_ARGS")"
stdin_data="$(cat "$FAKE_CURL_STDIN")"
assert_not_contains "$args" "$POOLY_DISCORD_WEBHOOK"
assert_contains "$stdin_data" "url = \"$POOLY_DISCORD_WEBHOOK\""
assert_contains "$args" "<--config>"
assert_contains "$args" "<->"
assert_contains "$args" "WEBHOOK_ENV=<unset>"

# Plain text Discord delivery uses the same protected transport.
: > "$FAKE_CURL_ARGS"
: > "$FAKE_CURL_STDIN"
: > "$FAKE_CURL_COUNT"
discord_post 'transport test message'
args="$(cat "$FAKE_CURL_ARGS")"
stdin_data="$(cat "$FAKE_CURL_STDIN")"
assert_not_contains "$args" "$POOLY_DISCORD_WEBHOOK"
assert_contains "$stdin_data" "url = \"$POOLY_DISCORD_WEBHOOK\""

# Rate-limit retry must keep the URL out of both curl argument lists.
: > "$FAKE_CURL_ARGS"
: > "$FAKE_CURL_STDIN"
: > "$FAKE_CURL_COUNT"
export FAKE_CURL_SCENARIO=retry
out="$(discord_post_json_file "$payload_file")"
assert_contains "$out" "DISCORD RESULT: PASS_AFTER_429_RETRY"
args="$(cat "$FAKE_CURL_ARGS")"
stdin_data="$(cat "$FAKE_CURL_STDIN")"
assert_not_contains "$args" "$POOLY_DISCORD_WEBHOOK"
[[ "$(grep -c '^CALL ' "$FAKE_CURL_ARGS")" == "2" ]] || fail "expected two curl calls during retry"
[[ "$(grep -c "url = \"$POOLY_DISCORD_WEBHOOK\"" "$FAKE_CURL_STDIN")" == "2" ]] || fail "webhook config was not supplied to both retry calls"

# Invalid domains are rejected before curl is executed and are never echoed.
: > "$FAKE_CURL_ARGS"
POOLY_DISCORD_WEBHOOK='https://example.invalid/api/webhooks/1/not-discord'
out="$(discord_post_json_file "$payload_file")"
assert_contains "$out" "DISCORD RESULT: FAIL_INVALID_WEBHOOK_FORMAT"
[[ ! -s "$FAKE_CURL_ARGS" ]] || fail "curl ran for an invalid webhook"
assert_not_contains "$out" "$POOLY_DISCORD_WEBHOOK"

# Curl-config injection characters are rejected before curl is executed.
: > "$FAKE_CURL_ARGS"
POOLY_DISCORD_WEBHOOK=$'https://discord.com/api/webhooks/123/token\noutput = "/tmp/pooly-webhook-injection"'
out="$(discord_post_json_file "$payload_file")"
assert_contains "$out" "DISCORD RESULT: FAIL_INVALID_WEBHOOK_FORMAT"
[[ ! -s "$FAKE_CURL_ARGS" ]] || fail "curl ran for an injected webhook value"
[[ ! -e /tmp/pooly-webhook-injection ]] || fail "injected curl config wrote a file"

# Static guard against reintroducing the secret as a curl command-line argument.
if grep -En 'curl[^\n]*\$\{?POOLY_DISCORD_WEBHOOK' "$ROOT/lib/discord.sh"; then
  fail "Discord webhook appears on a curl command line"
fi

printf 'PASS: Discord webhook transport tests\n'
