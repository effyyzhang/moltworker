#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config/workspace/skills from R2 via rclone (if configured)
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts a background sync loop (rclone, watches for file changes)
# 5. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
LAST_SYNC_FILE="/tmp/.last-sync"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# RCLONE SETUP
# ============================================================

r2_configured() {
    [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$CF_ACCOUNT_ID" ]
}

R2_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"

setup_rclone() {
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    touch /tmp/.rclone-configured
    echo "Rclone configured for bucket: $R2_BUCKET"
}

RCLONE_FLAGS="--transfers=16 --fast-list --s3-no-check-bucket"

# ============================================================
# RESTORE FROM R2
# ============================================================

if r2_configured; then
    setup_rclone

    echo "Checking R2 for existing backup..."
    # Check if R2 has an openclaw config backup
    if rclone ls "r2:${R2_BUCKET}/openclaw/openclaw.json" $RCLONE_FLAGS 2>/dev/null | grep -q openclaw.json; then
        echo "Restoring config from R2..."
        rclone copy "r2:${R2_BUCKET}/openclaw/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: config restore failed with exit code $?"
        echo "Config restored"
    elif rclone ls "r2:${R2_BUCKET}/clawdbot/clawdbot.json" $RCLONE_FLAGS 2>/dev/null | grep -q clawdbot.json; then
        echo "Restoring from legacy R2 backup..."
        rclone copy "r2:${R2_BUCKET}/clawdbot/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: legacy config restore failed with exit code $?"
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Legacy config restored and migrated"
    else
        echo "No backup found in R2, starting fresh"
    fi

    # Restore workspace
    REMOTE_WS_COUNT=$(rclone ls "r2:${R2_BUCKET}/workspace/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_WS_COUNT" -gt 0 ]; then
        echo "Restoring workspace from R2 ($REMOTE_WS_COUNT files)..."
        mkdir -p "$WORKSPACE_DIR"
        rclone copy "r2:${R2_BUCKET}/workspace/" "$WORKSPACE_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: workspace restore failed with exit code $?"
        echo "Workspace restored"
    fi

    # Restore skills
    REMOTE_SK_COUNT=$(rclone ls "r2:${R2_BUCKET}/skills/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_SK_COUNT" -gt 0 ]; then
        echo "Restoring skills from R2 ($REMOTE_SK_COUNT files)..."
        mkdir -p "$SKILLS_DIR"
        rclone copy "r2:${R2_BUCKET}/skills/" "$SKILLS_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: skills restore failed with exit code $?"
        echo "Skills restored"
    fi
else
    echo "R2 not configured, starting fresh"
fi

# ============================================================
# FORCE FRESH CONFIG when env vars change
# ============================================================
# Remove existing config so onboard always runs with current env vars.
# The patch step below will re-apply channel/gateway settings.
rm -f "$CONFIG_FILE"

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."

    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    fi

    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health

    echo "Onboard completed"
else
    echo "Using existing config"
fi

# After onboard completes, point OpenClaw workspace to our data directory
# so it discovers skills, IDENTITY.md, and knowledge files
rm -rf /root/.openclaw/workspace
ln -sf /root/clawd /root/.openclaw/workspace
echo "Workspace linked to /root/clawd"

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

// No token auth - CF Access handles external authentication at the worker level.
// The gateway runs inside a sandbox container that's only reachable via the worker.
if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

// ============================================================
// MCP PLUGIN CONFIGURATION
// ============================================================
// Configure openclaw-mcp-plugin to connect to MCP sidecar servers.
// Plugin key must match the directory name in ~/.openclaw/extensions/.

const mcpServers = {};

if (process.env.GOOGLE_OAUTH_CLIENT_ID && process.env.GOOGLE_OAUTH_CLIENT_SECRET) {
    mcpServers['google-workspace'] = {
        enabled: true,
        transport: 'http',
        url: 'http://localhost:3100/mcp',
    };
    console.log('MCP: Google Workspace server configured on port 3100');
}

if (process.env.NOTION_API_KEY) {
    mcpServers['notion'] = {
        enabled: true,
        transport: 'http',
        url: 'http://localhost:3101/mcp',
    };
    console.log('MCP: Notion server configured on port 3101');
}

if (Object.keys(mcpServers).length > 0) {
    config.plugins = config.plugins || {};
    config.plugins.enabled = true;
    config.plugins.allow = config.plugins.allow || [];
    if (!config.plugins.allow.includes('mcp-integration')) {
        config.plugins.allow.push('mcp-integration');
    }
    config.plugins.entries = config.plugins.entries || {};
    config.plugins.entries['mcp-integration'] = {
        enabled: true,
        config: {
            enabled: true,
            servers: mcpServers,
        },
    };
    console.log('MCP: Plugin configured with ' + Object.keys(mcpServers).length + ' server(s)');
} else {
    console.log('MCP: No MCP credentials provided, skipping plugin config');
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# START MCP SIDECARS
# ============================================================
# MCP servers run as HTTP sidecars via supergateway (stdio-to-HTTP bridge).
# The openclaw-mcp-plugin connects to them over HTTP.

MCP_SERVERS_STARTED=false

# Kill any stale MCP sidecar processes from previous startups
pkill -f "supergateway" 2>/dev/null || true
sleep 1

# Google Workspace MCP (Gmail, Calendar, Contacts, Drive)
if [ -n "$GOOGLE_OAUTH_CLIENT_ID" ] && [ -n "$GOOGLE_OAUTH_CLIENT_SECRET" ]; then
    echo "Starting Google Workspace MCP sidecar on port 3100..."

    # Write Google OAuth tokens for all configured accounts
    # google-workspace-mcp config dir (matches `google-workspace-mcp config path`)
    GOOGLE_CONFIG_DIR="/root/.google-mcp"
    GOOGLE_TOKEN_DIR="$GOOGLE_CONFIG_DIR/tokens"
    mkdir -p "$GOOGLE_TOKEN_DIR"

    # Write credentials.json (shared across all accounts)
    cat > "$GOOGLE_CONFIG_DIR/credentials.json" << EOFCREDS
{"installed":{"client_id":"$GOOGLE_OAUTH_CLIENT_ID","client_secret":"$GOOGLE_OAUTH_CLIENT_SECRET","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token","redirect_uris":["http://localhost"]}}
EOFCREDS

    # Write accounts.json and token files for each account
    ACCOUNTS_JSON='{"accounts":{'
    FIRST_ACCOUNT=true

    write_account_token() {
        local name="$1"
        local token="$2"
        if [ -n "$token" ]; then
            cat > "$GOOGLE_TOKEN_DIR/${name}.json" << EOFTOKEN
{"type":"authorized_user","client_id":"$GOOGLE_OAUTH_CLIENT_ID","client_secret":"$GOOGLE_OAUTH_CLIENT_SECRET","refresh_token":"$token"}
EOFTOKEN
            if [ "$FIRST_ACCOUNT" = true ]; then
                FIRST_ACCOUNT=false
            else
                ACCOUNTS_JSON="$ACCOUNTS_JSON,"
            fi
            ACCOUNTS_JSON="$ACCOUNTS_JSON\"$name\":{\"credentialsPath\":\"$GOOGLE_CONFIG_DIR/credentials.json\",\"tokenPath\":\"$GOOGLE_TOKEN_DIR/${name}.json\"}"
            echo "  Account '$name' configured"
        fi
    }

    write_account_token "build" "$GOOGLE_OAUTH_REFRESH_TOKEN"
    write_account_token "work" "$GOOGLE_OAUTH_REFRESH_TOKEN_WORK"
    write_account_token "personal" "$GOOGLE_OAUTH_REFRESH_TOKEN_PERSONAL"

    ACCOUNTS_JSON="$ACCOUNTS_JSON},\"credentialsPath\":\"$GOOGLE_CONFIG_DIR/credentials.json\"}"
    echo "$ACCOUNTS_JSON" > "$GOOGLE_CONFIG_DIR/accounts.json"
    echo "Google accounts written to $GOOGLE_CONFIG_DIR"

    GOOGLE_OAUTH_CLIENT_ID="$GOOGLE_OAUTH_CLIENT_ID" \
    GOOGLE_OAUTH_CLIENT_SECRET="$GOOGLE_OAUTH_CLIENT_SECRET" \
    supergateway --stdio "npx -y google-workspace-mcp" --outputTransport streamableHttp --port 3100 &
    MCP_SERVERS_STARTED=true
    echo "Google Workspace MCP sidecar started"
fi

# Notion MCP
if [ -n "$NOTION_API_KEY" ]; then
    echo "Starting Notion MCP sidecar on port 3101..."
    OPENAPI_MCP_HEADERS="{\"Authorization\": \"Bearer $NOTION_API_KEY\", \"Notion-Version\": \"2022-06-28\"}" \
    supergateway --stdio "npx -y @notionhq/notion-mcp-server" --outputTransport streamableHttp --port 3101 &
    MCP_SERVERS_STARTED=true
    echo "Notion MCP sidecar started"
fi

if [ "$MCP_SERVERS_STARTED" = true ]; then
    echo "Waiting for MCP sidecars to initialize..."
    sleep 3
fi

# ============================================================
# GENERATE IDENTITY.md FROM KNOWLEDGE BASE
# ============================================================
# Assemble IDENTITY.md from the knowledge/IDENTITY/ files so the bot
# has persistent context about the user on every conversation.
IDENTITY_FILE="$WORKSPACE_DIR/IDENTITY.md"
KNOWLEDGE_IDENTITY="$WORKSPACE_DIR/knowledge/IDENTITY"

if [ -d "$KNOWLEDGE_IDENTITY" ]; then
    echo "Generating IDENTITY.md from knowledge base..."
    : > "$IDENTITY_FILE"

    for f in profile.md preferences.md goals.md; do
        if [ -f "$KNOWLEDGE_IDENTITY/$f" ]; then
            cat "$KNOWLEDGE_IDENTITY/$f" >> "$IDENTITY_FILE"
            echo "" >> "$IDENTITY_FILE"
        fi
    done

    cat >> "$IDENTITY_FILE" << 'EOFIDENTITY'
## Agent Rules

- You are Effy's personal AI assistant with access to a shared knowledge base.
- Before responding, check relevant knowledge:
  - Person mentioned → search with search.js or read people/_index.md
  - Project question → read the project file in projects/
  - Schedule/availability question → check IDENTITY/preferences.md
- After learning something new, write it back:
  - New info about a person → update their file in people/
  - Important event or decision → append to journal with journal.js
  - Project status change → update the project file
- Never share personal info (IDENTITY/, people/) with anyone other than Effy unless she explicitly asks.
- Use Pacific Time (PT) for all timestamps and scheduling.
- Keep responses concise and direct.
EOFIDENTITY

    echo "IDENTITY.md generated at $IDENTITY_FILE"
else
    echo "No knowledge/IDENTITY/ directory found, skipping IDENTITY.md generation"
fi

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

# No token auth - CF Access handles external authentication at the worker level.
echo "Starting gateway without token auth (CF Access protects external access)..."
exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
