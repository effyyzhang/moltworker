#!/usr/bin/env node
/**
 * Pull knowledge base from R2 to local filesystem.
 *
 * The OpenClaw container syncs /root/clawd/ to R2 every 5 minutes.
 * Knowledge lives at R2: workspace/knowledge/
 * This script pulls those files to the local knowledge/ directory.
 *
 * Credentials: set R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, CF_ACCOUNT_ID
 * as env vars, or add them to open_claw/.dev.vars
 *
 * Usage: node scripts/pull-knowledge.mjs [--dry-run]
 */

import { S3Client, ListObjectsV2Command, GetObjectCommand } from '@aws-sdk/client-s3';
import { readFileSync, mkdirSync, writeFileSync, existsSync } from 'fs';
import { join, dirname, resolve } from 'path';
import { fileURLToPath } from 'url';
import { Readable } from 'stream';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(__dirname, '..');
const KNOWLEDGE_DIR = resolve(PROJECT_ROOT, '..', 'knowledge');

const BUCKET = 'moltbot-data';
const R2_PREFIX = 'workspace/knowledge/';

// Files to skip (agent-only, not useful locally)
const SKIP_FILES = new Set(['CLAUDE.md']);

function loadDevVars() {
  const devVarsPath = join(PROJECT_ROOT, '.dev.vars');
  if (!existsSync(devVarsPath)) return {};
  const vars = {};
  for (const line of readFileSync(devVarsPath, 'utf-8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const eq = trimmed.indexOf('=');
    if (eq === -1) continue;
    vars[trimmed.slice(0, eq)] = trimmed.slice(eq + 1);
  }
  return vars;
}

function getCredentials() {
  const devVars = loadDevVars();
  const get = (key) => process.env[key] || devVars[key];

  const accessKeyId = get('R2_ACCESS_KEY_ID');
  const secretAccessKey = get('R2_SECRET_ACCESS_KEY');
  const accountId = get('CF_ACCOUNT_ID');

  if (!accessKeyId || !secretAccessKey || !accountId) {
    console.error('Missing R2 credentials. Set these as env vars or in .dev.vars:');
    console.error('  R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, CF_ACCOUNT_ID');
    process.exit(1);
  }

  return { accessKeyId, secretAccessKey, accountId };
}

async function streamToBuffer(stream) {
  const chunks = [];
  for await (const chunk of stream) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

async function main() {
  const dryRun = process.argv.includes('--dry-run');
  const { accessKeyId, secretAccessKey, accountId } = getCredentials();

  const client = new S3Client({
    region: 'auto',
    endpoint: `https://${accountId}.r2.cloudflarestorage.com`,
    credentials: { accessKeyId, secretAccessKey },
  });

  // List all knowledge objects in R2
  console.log(`Listing R2 objects with prefix: ${R2_PREFIX}`);
  const allKeys = [];
  let continuationToken;

  do {
    const cmd = new ListObjectsV2Command({
      Bucket: BUCKET,
      Prefix: R2_PREFIX,
      ContinuationToken: continuationToken,
    });
    const resp = await client.send(cmd);
    if (resp.Contents) {
      allKeys.push(...resp.Contents);
    }
    continuationToken = resp.IsTruncated ? resp.NextContinuationToken : undefined;
  } while (continuationToken);

  if (allKeys.length === 0) {
    console.log('No knowledge files found in R2. Has the container synced yet?');
    process.exit(0);
  }

  console.log(`Found ${allKeys.length} objects in R2\n`);

  let downloaded = 0;
  let skipped = 0;

  for (const obj of allKeys) {
    // Strip prefix to get relative path: workspace/knowledge/me/about.md -> me/about.md
    const relPath = obj.Key.slice(R2_PREFIX.length);
    if (!relPath) continue; // skip the prefix itself

    // Skip directories (keys ending in /)
    if (relPath.endsWith('/')) continue;

    // Skip excluded files
    const filename = relPath.split('/').pop();
    if (SKIP_FILES.has(filename)) {
      skipped++;
      continue;
    }

    const localPath = join(KNOWLEDGE_DIR, relPath);
    const size = obj.Size || 0;
    const modified = obj.LastModified ? obj.LastModified.toISOString().slice(0, 19) : '?';

    if (dryRun) {
      console.log(`  [dry-run] ${relPath} (${size}B, ${modified})`);
      downloaded++;
      continue;
    }

    // Download and write
    const getCmd = new GetObjectCommand({ Bucket: BUCKET, Key: obj.Key });
    const resp = await client.send(getCmd);
    const body = await streamToBuffer(resp.Body);

    mkdirSync(dirname(localPath), { recursive: true });
    writeFileSync(localPath, body);
    console.log(`  ${relPath} (${size}B)`);
    downloaded++;
  }

  console.log(`\n${dryRun ? 'Would pull' : 'Pulled'} ${downloaded} files, skipped ${skipped}`);
  console.log(`Knowledge directory: ${KNOWLEDGE_DIR}`);
}

main().catch((err) => {
  console.error('Error:', err.message);
  process.exit(1);
});
