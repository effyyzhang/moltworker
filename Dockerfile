FROM docker.io/cloudflare/sandbox:0.7.0

# Install Node.js 22 (required by OpenClaw) and rclone (for R2 persistence)
# The base image has Node 20, we need to replace it with Node 22
# Using direct binary download for reliability
ENV NODE_VERSION=22.13.1
RUN ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
         amd64) NODE_ARCH="x64" ;; \
         arm64) NODE_ARCH="arm64" ;; \
         *) echo "Unsupported architecture: ${ARCH}" >&2; exit 1 ;; \
       esac \
    && apt-get update && apt-get install -y xz-utils ca-certificates rclone \
    && curl -fsSLk https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version \
    && npm --version

# Install pnpm globally
RUN npm install -g pnpm

# Install OpenClaw (formerly clawdbot/moltbot)
# Pin to specific version for reproducible builds
RUN npm install -g openclaw@2026.2.3 \
    && openclaw --version

# Create OpenClaw directories
# Legacy .clawdbot paths are kept for R2 backup migration
RUN mkdir -p /root/.openclaw \
    && mkdir -p /root/.openclaw/extensions \
    && mkdir -p /root/clawd \
    && mkdir -p /root/clawd/skills

# Install MCP plugin for OpenClaw (connects to MCP servers over HTTP)
# Post-clone fixups: the upstream repo is missing the openclaw.extensions
# field in package.json (required for plugin discovery) and has the manifest
# in config/ instead of the root. Patch both so OpenClaw can find it.
RUN cd /root/.openclaw/extensions \
    && git clone https://github.com/lunarpulse/openclaw-mcp-plugin.git mcp-integration \
    && cd mcp-integration \
    && cp config/openclaw.plugin.json openclaw.plugin.json \
    && node -e "const p=require('./package.json'); p.openclaw={extensions:['./src/index.js']}; require('fs').writeFileSync('package.json',JSON.stringify(p,null,2)+'\n')" \
    && npm install

# Install MCP servers and supergateway (stdio-to-HTTP bridge)
# supergateway wraps stdio MCP servers as HTTP endpoints for the plugin
RUN npm install -g supergateway google-workspace-mcp @notionhq/notion-mcp-server

# Copy startup script
# Build cache bust: 2026-02-15-v39-workspace-symlink
COPY start-openclaw.sh /usr/local/bin/start-openclaw.sh
RUN chmod +x /usr/local/bin/start-openclaw.sh

# Copy knowledge base (data + skill scripts, preserving directory structure)
COPY knowledge/ /root/clawd/knowledge/

# Copy other skills (browser, etc.)
COPY skills/ /root/clawd/skills/

# Auto-discover skills from knowledge/skills/
RUN for d in /root/clawd/knowledge/skills/*/; do \
  name=$(basename "$d"); \
  [ ! -e "/root/clawd/skills/$name" ] && ln -sf "$d" "/root/clawd/skills/$name"; \
done

# Set working directory
WORKDIR /root/clawd

# Expose the gateway port and MCP sidecar ports
EXPOSE 18789 3100 3101
