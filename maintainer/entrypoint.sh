#!/bin/bash
set -euo pipefail

echo "=== Gasclaw Maintainer Agent ==="
echo ""

# --- Auth ---
echo "$GITHUB_TOKEN" | gh auth login --with-token --hostname github.com 2>&1 || true
gh auth status 2>&1 || true
git config --global url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
git config --global user.email "gasclaw-bot@gastown.dev"
git config --global user.name "Gasclaw Maintainer"

# --- Kimi K2.5 as Claude Code backend ---
export ANTHROPIC_BASE_URL="https://api.kimi.com/coding/"
export ANTHROPIC_API_KEY="${KIMI_API_KEY}"
export DISABLE_COST_WARNINGS=true

# --- Telegram config (from env, set in .env / docker-compose) ---
: "${TELEGRAM_BOT_TOKEN:?TELEGRAM_BOT_TOKEN is required}"
: "${TELEGRAM_CHAT_ID:?TELEGRAM_CHAT_ID is required}"

# --- Claude Code config (isolated, API key auth) ---
export CLAUDE_CONFIG_DIR="/workspace/.claude-config"
mkdir -p "$CLAUDE_CONFIG_DIR"
echo '{}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
FINGERPRINT="${KIMI_API_KEY:(-20)}"
cat > "$CLAUDE_CONFIG_DIR/.claude.json" <<CJSON
{
  "hasCompletedOnboarding": true,
  "bypassPermissionsModeAccepted": true,
  "customApiKeyResponses": {
    "approved": ["${FINGERPRINT}"]
  }
}
CJSON

# --- Helper: send Telegram message ---
tg_send() {
    curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TELEGRAM_CHAT_ID}" \
        -d parse_mode=Markdown \
        -d text="$1" > /dev/null 2>&1 || true
}

# --- OpenClaw config (Telegram two-way chat with full agent context) ---
echo "Configuring OpenClaw..."
OPENCLAW_DIR="$HOME/.openclaw"
mkdir -p "$OPENCLAW_DIR"
mkdir -p "$OPENCLAW_DIR/agents/main/agent"
mkdir -p "$OPENCLAW_DIR/agents/main/sessions"

# Write config using Python for clean JSON generation with env vars
python3 << 'PYEOF'
import json, os

openclaw_dir = os.path.expanduser("~/.openclaw")

# 1. Write models.json (custom Kimi provider)
models = {
    "providers": {
        "kimi-coding": {
            "baseUrl": "https://api.kimi.com/coding/",
            "api": "anthropic-messages",
            "models": [{
                "id": "k2p5",
                "name": "Kimi for Coding",
                "reasoning": True,
                "input": ["text", "image"],
                "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                "contextWindow": 262144,
                "maxTokens": 32768,
            }],
            "apiKey": os.environ["KIMI_API_KEY"],
        }
    }
}
models_path = os.path.join(openclaw_dir, "agents/main/agent/models.json")
with open(models_path, "w") as f:
    json.dump(models, f, indent=2)

# 2. Write openclaw.json (main config with agent instructions)
agent_instructions = """You are the Gasclaw Maintainer Bot — the autonomous overseer of the gasclaw project (github.com/gastown-publish/gasclaw).

PROJECT OVERVIEW:
Gasclaw is a single-container deployment combining:
- Gastown (gt): Multi-agent AI workspace with mayor, deacon, witness, refinery, crew
- OpenClaw (you): Telegram bot overseer that monitors and reports
- KimiGas: Kimi K2.5 API proxy that lets Claude Code run via Kimi's API

All agents use Kimi K2.5 API keys via api.kimi.com/coding/ (NOT direct Anthropic/Claude API keys).

YOUR ROLE:
- Monitor the gasclaw repository and its Claude Code maintainer agent
- Report status, test results, PR activity, and issues to the human via Telegram
- Run shell commands to get real-time data from the workspace
- You have full shell access

PROJECT STATE:
- Repo: /workspace/gasclaw (github.com/gastown-publish/gasclaw)
- Tech: Python 3.13, 413+ unit tests, Kimi K2.5 via api.kimi.com/coding/
- Claude Code runs autonomously: creates PRs, merges them, fixes issues
- The maintainer agent has FULL merge authority on the repo

COMMANDS TO USE:
- gh pr list --repo gastown-publish/gasclaw --state open (check open PRs)
- gh pr list --repo gastown-publish/gasclaw --state merged --limit 10 (recent merges)
- gh issue list --repo gastown-publish/gasclaw --state open (check issues)
- cd /workspace/gasclaw && python -m pytest tests/unit --tb=short 2>&1 | tail -5 (test status)
- git -C /workspace/gasclaw log --oneline -10 (recent commits)
- docker logs gasclaw-maintainer --tail 20 2>&1 (container logs)
- cat /tmp/openclaw-gateway.log | tail -20 (your gateway log)

WHEN ASKED FOR STATUS:
- Run the commands above to get LIVE data
- Report: test count, open PRs, open issues, recent merges, agent health
- Never guess — always run commands first

BEHAVIOR:
- Be concise and informative
- Always run commands to get real data before answering
- If you don't know something, say so and offer to investigate
- You have full shell access — use it"""

config = {
    "agents": {
        "defaults": {
            "model": {"primary": "kimi-coding/k2p5"},
            "models": {"kimi-coding/k2p5": {}},
        },
        "list": [{
            "id": "main",
            "identity": {"name": "Gasclaw Maintainer", "emoji": "\U0001f3ed"},
            "instructions": agent_instructions,
        }],
    },
    "channels": {
        "telegram": {
            "botToken": os.environ["TELEGRAM_BOT_TOKEN"],
            "dmPolicy": "allowlist",
            "allowFrom": [os.environ["TELEGRAM_CHAT_ID"]],
        }
    },
    "commands": {"native": "auto", "nativeSkills": "auto", "restart": True},
    "gateway": {"port": 18789, "mode": "local"},
    "plugins": {"slots": {"memory": "none"}},
    "tools": {"exec": {"security": "full"}},
    "env": {"KIMI_API_KEY": os.environ["KIMI_API_KEY"]},
}

config_path = os.path.join(openclaw_dir, "openclaw.json")
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)

print("OpenClaw config written (models.json + openclaw.json)")
PYEOF

# --- Clone repo (persistent on /workspace volume) ---
echo "Cloning gasclaw..."
if [ -d /workspace/gasclaw/.git ]; then
    cd /workspace/gasclaw && git pull origin main
else
    git clone https://github.com/gastown-publish/gasclaw.git /workspace/gasclaw
    cd /workspace/gasclaw
fi

# --- Dev setup (venv on persistent volume) ---
echo "Setting up dev environment..."
if [ ! -d .venv ]; then
    python3 -m venv .venv
fi
source .venv/bin/activate
echo "Upgrading pip..."
pip install --upgrade pip --timeout 120 --retries 5
echo "Installing gasclaw + deps..."
pip install --timeout 120 --retries 5 -e .
echo "Installing test deps..."
pip install --timeout 120 --retries 5 pytest pytest-asyncio respx

# --- Verify tests pass (non-fatal, bot can fix failures) ---
echo "Running tests..."
TEST_COUNT=$(python -m pytest tests/unit -v 2>&1 | tail -1) || true
echo "$TEST_COUNT"

# --- Start OpenClaw gateway (background, for Telegram two-way chat) ---
echo "Starting OpenClaw gateway..."
openclaw doctor --fix --yes 2>&1 || true
nohup openclaw gateway run > /tmp/openclaw-gateway.log 2>&1 &
GATEWAY_PID=$!
sleep 5
if kill -0 "$GATEWAY_PID" 2>/dev/null; then
    echo "OpenClaw gateway running (PID $GATEWAY_PID)"
else
    echo "WARNING: OpenClaw gateway failed to start"
    cat /tmp/openclaw-gateway.log 2>/dev/null || true
fi

tg_send "🏭 *Gasclaw Maintainer online*
Tests: ${TEST_COUNT}
Telegram: connected
Ready to work."

# --- Launch Claude Code as maintainer ---
echo ""
echo "Starting Claude Code maintainer loop..."

MAINTAINER_PROMPT='You are the gasclaw repo maintainer with FULL merge authority. Read CLAUDE.md first.

TELEGRAM REPORTING: After every significant action, send a Telegram update using this command:
curl -s "https://api.telegram.org/bot'${TELEGRAM_BOT_TOKEN}'/sendMessage" -d chat_id="'${TELEGRAM_CHAT_ID}'" -d parse_mode=Markdown -d text="YOUR_MESSAGE"

Send updates for: PR created, PR merged, issue fixed, tests status, errors encountered.

Your continuous maintenance loop:

1. Check PRs: gh pr list --repo gastown-publish/gasclaw --state open
2. For EACH open PR:
   a. Check out the branch: gh pr checkout <number>
   b. Run tests: python -m pytest tests/unit -v
   c. If tests pass: merge it immediately with gh pr merge <number> --squash --delete-branch
   d. If tests fail: fix the issues on the branch, push, then merge
   e. After merging: git checkout main and git pull
   f. Send Telegram update: "Merged PR #N: title"
3. Check issues: gh issue list --repo gastown-publish/gasclaw --state open
4. Fix open issues: Branch, implement with tests, create PR, then immediately merge it
5. Improve test coverage: Find untested paths, add edge case tests, create PR, merge it
6. Code quality: Fix lint issues, improve types/error handling, create PR, merge it
7. Report issues: If you find bugs you cannot fix in one PR, file an issue

IMPORTANT: You have merge authority. After creating a PR, verify tests pass, then merge it yourself using gh pr merge --squash --delete-branch. Do not leave PRs open.

After completing each task, move to the next. When all tasks done, send a Telegram summary and look for improvements.

Rules:
- Always branch from latest main: git checkout main and git pull
- Branch naming: fix/, feat/, test/, docs/, refactor/
- Run python -m pytest tests/unit -v before every commit
- One concern per PR, keep PRs small (under 200 lines)
- Never push to main directly, always use PRs, then merge them
- Write tests first (TDD)
- Always merge your own PRs after tests pass
- Send Telegram updates after each action

Start now. Begin by reading CLAUDE.md, then check and merge any open PRs first.'

exec claude --dangerously-skip-permissions -p "$MAINTAINER_PROMPT"
