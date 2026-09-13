#!/usr/bin/env node
// Anonymous, read-only verification. Downloaded content is never executed or saved.
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, realpath, stat } from 'node:fs/promises';
import { dirname, resolve, sep } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { crc32, inflateSync } from 'node:zlib';

export const REPO = 'zarubinvibe/iriz';
export const API = `https://api.github.com/repos/${REPO}`;
export const DOWNLOAD = `https://github.com/${REPO}/releases`;
export const STABLE = `${DOWNLOAD}/latest/download/iriz-macos-arm64.dmg`;
const HOSTS = new Set(['github.com', 'api.github.com', 'release-assets.githubusercontent.com']);
const META_LIMIT = 1024 * 1024;
const DMG_LIMIT = 512 * 1024 * 1024;
const HASH = /^[a-f0-9]{64}$/;
const SHA = /^[a-f0-9]{40}$/;
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const LOCALES = [['README.md', 'What This Is', 'Contents'], ['README.ru.md', 'Что это', 'Оглавление'], ['README.zh.md', '这是什么', '目录']];
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
const requireThat = (condition, message) => { if (!condition) throw new Error(message); };
const sameNames = (actual, expected, label) => {
  requireThat(Array.isArray(actual) && actual.length === expected.length &&
    new Set(actual).size === actual.length && expected.every(name => actual.includes(name)), `${label}: wrong or duplicate filenames`);
};

export function trustedURL(value) {
  let url;
  try { url = new URL(value); } catch { throw new Error('Invalid download URL'); }
  requireThat(url.protocol === 'https:' && HOSTS.has(url.hostname) && !url.username &&
    !url.password && !url.port && !url.hash, 'Untrusted download URL');
  return url;
}

export async function request(url, {
  fetchImpl = globalThis.fetch, maxBytes = META_LIMIT, expectedBytes,
  capture = true, dmg = false, timeoutMs = 180_000, deadline = Date.now() + 600_000,
  attempts = 2, retryDelayMs = 1000,
} = {}) {
  trustedURL(url);
  requireThat(Number.isInteger(attempts) && attempts >= 1 && attempts <= 2, 'Invalid retry bound');
  let lastError;
  for (let attempt = 0; attempt < attempts; attempt++) {
    const controller = new AbortController();
    const remaining = Math.min(timeoutMs, deadline - Date.now());
    requireThat(remaining > 0, 'Download verification deadline exceeded');
    const timer = setTimeout(() => controller.abort(), remaining);
    let response;
    try {
      let current = url;
      const redirects = [];
      for (let hop = 0; hop <= 5; hop++) {
        trustedURL(current);
        try {
          response = await fetchImpl(current, {
            redirect: 'manual', credentials: 'omit', signal: controller.signal,
            headers: { Accept: 'application/octet-stream, application/json',
              'Accept-Encoding': 'identity', 'Cache-Control': 'no-cache',
              'User-Agent': 'iriz-anonymous-download-check' },
          });
        } catch {
          const error = new Error(controller.signal.aborted ? 'Download request timed out' : 'Anonymous network request failed');
          error.retryable = true;
          throw error;
        }
        if (![301, 302, 303, 307, 308].includes(response.status)) break;
        await response.body?.cancel();
        requireThat(hop < 5, 'Too many download redirects');
        const location = response.headers.get('location');
        requireThat(location, 'Redirect has no Location');
        current = trustedURL(new URL(location, current).href).href;
        redirects.push(current);
      }
      if (response.status !== 200) {
        const quota = response.status === 403 && response.headers.get('x-ratelimit-remaining') === '0';
        const error = new Error(quota ? 'Anonymous GitHub API rate limit exhausted; download integrity is unverified' : `Anonymous HTTP request returned ${response.status}`);
        error.retryable = response.status === 429 || response.status >= 500;
        throw error;
      }
      requireThat(!/html/i.test(response.headers.get('content-type') || ''), 'HTML returned instead of a release file');
      requireThat(!response.headers.get('content-encoding') || response.headers.get('content-encoding') === 'identity', 'Unexpected content encoding');
      const length = response.headers.get('content-length');
      if (length !== null) {
        requireThat(/^\d+$/.test(length) && Number.isSafeInteger(Number(length)) && Number(length) <= maxBytes, 'Invalid or oversized Content-Length');
        if (expectedBytes !== undefined) requireThat(Number(length) === expectedBytes, 'Content-Length differs from asset size');
      }
      requireThat(response.body, 'Empty response body');
      const hash = createHash('sha256');
      const chunks = [];
      let bytes = 0;
      let prefix = Buffer.alloc(0);
      let tail = Buffer.alloc(0);
      try {
        for await (const part of response.body) {
          const chunk = Buffer.from(part);
          bytes += chunk.length;
          requireThat(bytes <= maxBytes && (expectedBytes === undefined || bytes <= expectedBytes), 'Response body exceeds its size limit');
          if (prefix.length < 512) prefix = Buffer.concat([prefix, chunk.subarray(0, 512 - prefix.length)]);
          requireThat(!/^\s*<(?:!doctype\s+html|html|head|body)\b/i.test(prefix.toString('utf8')), 'HTML returned instead of a release file');
          hash.update(chunk);
          if (capture) chunks.push(chunk);
          if (dmg) tail = Buffer.concat([tail, chunk]).subarray(-512);
        }
      } catch (error) {
        if (controller.signal.aborted) {
          const timeout = new Error('Download body timed out');
          timeout.retryable = true;
          throw timeout;
        }
        throw error;
      }
      requireThat(bytes > 0, 'Empty response body');
      requireThat(length === null || bytes === Number(length), 'Truncated response body');
      requireThat(expectedBytes === undefined || bytes === expectedBytes, 'Downloaded size differs from release metadata');
      if (dmg) requireThat(bytes >= 512 && tail.subarray(0, 4).toString('ascii') === 'koly', 'Invalid DMG trailer');
      return { bytes, sha256: hash.digest('hex'), body: capture ? Buffer.concat(chunks) : undefined, redirects };
    } catch (error) {
      lastError = error;
      if (!error.retryable || attempt + 1 === attempts || Date.now() + retryDelayMs >= deadline) throw error;
    } finally {
      clearTimeout(timer);
      controller.abort();
    }
    await new Promise(done => setTimeout(done, retryDelayMs));
  }
  throw lastError;
}

function json(bytes, label) {
  try { return JSON.parse(bytes.toString('utf8')); } catch { throw new Error(`${label}: invalid JSON`); }
}

export function releaseSnapshot(release) {
  requireThat(release && Number.isSafeInteger(release.id) && release.id > 0 &&
    release.draft === false && release.prerelease === false && /^v\d+\.\d+\.\d+$/.test(release.tag_name), 'Invalid latest release metadata');
  const version = release.tag_name.slice(1);
  const names = [`iriz-${version}-arm64.dmg`, 'iriz-macos-arm64.dmg', 'release-manifest.json', 'SHA256SUMS.txt'];
  sameNames(release.assets?.map(asset => asset.name), names, 'Release assets');
  const assets = names.map(name => {
    const asset = release.assets.find(item => item.name === name);
    requireThat(Number.isSafeInteger(asset.id) && asset.id > 0 && asset.state === 'uploaded' &&
      Number.isSafeInteger(asset.size) && asset.size > 0 && asset.size <= (name.endsWith('.dmg') ? DMG_LIMIT : META_LIMIT), `Invalid asset metadata: ${name}`);
    requireThat(/^sha256:[a-f0-9]{64}$/.test(asset.digest), `Missing or invalid GitHub digest: ${name}`);
    const url = `${DOWNLOAD}/download/${release.tag_name}/${name}`;
    requireThat(asset.browser_download_url === url, `Unexpected asset URL: ${name}`);
    return { name, id: asset.id, size: asset.size, digest: asset.digest.slice(7), url, updated_at: asset.updated_at };
  });
  return { id: release.id, tag: release.tag_name, version, assets };
}

export function checksums(bytes, expected) {
  const result = new Map();
  const lines = bytes.toString('utf8').split(/\r?\n/);
  if (lines.at(-1) === '') lines.pop();
  for (const line of lines) {
    const match = /^([a-f0-9]{64})  ([a-zA-Z0-9._-]+)$/.exec(line);
    requireThat(match && expected.includes(match[2]) && !result.has(match[2]), 'Invalid, duplicate or unexpected checksum filename');
    result.set(match[2], match[1]);
  }
  sameNames([...result.keys()], expected, 'Checksums');
  return result;
}

export function validateManifest(manifest, snapshot, downloaded) {
  requireThat(manifest?.version === snapshot.version && manifest.source_dirty === false && SHA.test(manifest.source_sha), 'Manifest version/source is invalid');
  const images = snapshot.assets.filter(asset => asset.name.endsWith('.dmg'));
  sameNames(manifest.artifacts?.map(item => item.file), images.map(item => item.name), 'Manifest artifacts');
  for (const asset of images) {
    const item = manifest.artifacts.find(entry => entry.file === asset.name);
    requireThat(item.bytes === asset.size && item.sha256 === downloaded.get(asset.name).sha256 &&
      Array.isArray(item.architectures) && item.architectures.length === 1 && item.architectures[0] === 'arm64', `Manifest artifact differs: ${asset.name}`);
  }
  // v0.2.2 was accepted independently; later documentation edits must not rewrite it.
  if (snapshot.version === '0.2.2') {
    requireThat(manifest.source_sha === 'dfb97e9069682da2ec9cc2dd4edce7e61ae051f6', 'Frozen v0.2.2 source changed');
    for (const image of images) requireThat(downloaded.get(image.name).sha256 ===
      'bbfa8c6f2e5988e087ef5e1f255f0a477b152cf108aaccf299f0cb60d95a1110', 'Frozen v0.2.2 image changed');
  }
}

export async function verifyRelease(options = {}) {
  const deadline = Date.now() + 600_000;
  const get = (url, extra = {}) => request(url, { ...options, deadline, ...extra });
  const getJSON = async url => json((await get(url, { timeoutMs: 30_000 })).body, 'GitHub API');
  const snapshot = releaseSnapshot(await getJSON(`${API}/releases/latest`));
  const downloaded = new Map();
  for (const asset of snapshot.assets) {
    const stable = asset.name === 'iriz-macos-arm64.dmg';
    const result = await get(stable ? STABLE : asset.url, {
      maxBytes: asset.name.endsWith('.dmg') ? DMG_LIMIT : META_LIMIT,
      expectedBytes: asset.size, capture: !asset.name.endsWith('.dmg'), dmg: asset.name.endsWith('.dmg'),
    });
    requireThat(!stable || result.redirects.includes(asset.url), 'Stable URL resolved to another release');
    requireThat(result.sha256 === asset.digest, `GitHub SHA-256 mismatch: ${asset.name}`);
    downloaded.set(asset.name, result);
  }
  const versioned = downloaded.get(`iriz-${snapshot.version}-arm64.dmg`);
  const stable = downloaded.get('iriz-macos-arm64.dmg');
  requireThat(stable.sha256 === versioned.sha256 && stable.bytes === versioned.bytes, 'Stable and versioned images differ');
  const expectedSums = snapshot.assets.map(asset => asset.name).filter(name => name !== 'SHA256SUMS.txt');
  for (const [name, hash] of checksums(downloaded.get('SHA256SUMS.txt').body, expectedSums))
    requireThat(downloaded.get(name).sha256 === hash, `SHA256SUMS mismatch: ${name}`);
  const manifest = json(downloaded.get('release-manifest.json').body, 'Manifest');
  validateManifest(manifest, snapshot, downloaded);
  const ref = await getJSON(`${API}/git/ref/tags/${snapshot.tag}`);
  requireThat(ref.ref === `refs/tags/${snapshot.tag}`, 'Release tag ref differs');
  let object = ref.object;
  for (let depth = 0; object?.type === 'tag' && depth < 3; depth++) {
    requireThat(SHA.test(object.sha), 'Invalid annotated tag SHA');
    const tag = await getJSON(`${API}/git/tags/${object.sha}`);
    requireThat(tag.sha === object.sha, 'Annotated tag SHA differs');
    object = tag.object;
  }
  requireThat(object?.type === 'commit' && object.sha === manifest.source_sha, 'Release tag does not resolve to manifest source');
  const commit = await getJSON(`${API}/commits/${manifest.source_sha}`);
  requireThat(commit.sha === manifest.source_sha, 'Manifest source commit does not exist');
  const finalSnapshot = releaseSnapshot(await getJSON(`${API}/releases/latest`));
  requireThat(JSON.stringify(snapshot) === JSON.stringify(finalSnapshot), 'Latest release changed during verification; rerun against a stable release');
  return { version: snapshot.version, source_sha: manifest.source_sha, bytes: stable.bytes, sha256: stable.sha256 };
}

function attribute(tag, name) {
  return new RegExp(`(?:^|\\s)${name}\\s*=\\s*(["'])(.*?)\\1`, 'i').exec(tag)?.[2];
}

export function validateReadme(text, filename, heading, badgePath) {
  const start = '<!-- application-downloads:start -->';
  const end = '<!-- application-downloads:end -->';
  // Check rendered content, including whether the entire block was commented out.
  text = text.replace(/<!--[\s\S]*?-->/g, comment => [start, end].includes(comment) ? comment : '');
  let fence;
  text = text.split('\n').filter(line => {
    const marker = /^ {0,3}(`{3,}|~{3,})(.*)$/.exec(line);
    if (fence) {
      if (marker && marker[1][0] === fence[0] && marker[1].length >= fence.length && !marker[2].trim()) fence = undefined;
      return false;
    }
    if (marker) { fence = marker[1]; return false; }
    return !/^(?: {4}|\t)/.test(line);
  }).join('\n').replace(/<(pre|code)\b[^>]*>[\s\S]*?(?:<\/\1\s*>|$)/gi, '');
  requireThat(text.split(start).length === 2 && text.split(end).length === 2, `${filename}: one application download block required`);
  const from = text.indexOf(start), to = text.indexOf(end);
  const what = text.indexOf(`\n## ${heading}\n`);
  const contents = text.indexOf(`\n## ${LOCALES.find(([name]) => name === filename)?.[2]}\n`);
  requireThat(contents >= 0 && contents < from && from < to && what > to, `${filename}: application download must follow Contents and precede ${heading}`);
  const block = text.slice(from + start.length, to);
  const images = [...block.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/gi)]
    .filter(match => /<img\b/i.test(match[2]));
  requireThat(images.length === 1 && attribute(images[0][1], 'href') === STABLE,
    `${filename}: one linked application badge required`);
  const image = /<img\b([^>]*)>/i.exec(images[0][2]);
  requireThat(image && attribute(image[1], 'src') === badgePath && attribute(image[1], 'alt')?.trim() &&
    attribute(image[1], 'width') === '180', `${filename}: application badge image/alt/width differs`);
  const oldShield = /\[!\[[^\]]*\]\(https:\/\/img\.shields\.io\/[^\n]*\)\]\(https:\/\/github\.com\/zarubinvibe\/iriz\/releases\/latest\/download\/iriz-macos-arm64\.dmg\)/;
  requireThat(!oldShield.test(text), `${filename}: obsolete Shields download CTA remains`);
  for (const match of text.matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/gi)) {
    if (attribute(match[1], 'href') === STABLE && /<img\b/i.test(match[2]))
      requireThat(match.index > from && match.index < to, `${filename}: application badge outside its block`);
  }
}

export function validateBadgePNG(png) {
  requireThat(png.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])), 'Invalid badge PNG signature');
  const compressed = [];
  let width, height, ended = false;
  for (let offset = 8; offset < png.length;) {
    requireThat(offset + 12 <= png.length, 'Truncated badge PNG chunk');
    const length = png.readUInt32BE(offset), type = png.toString('ascii', offset + 4, offset + 8);
    const end = offset + length + 12;
    requireThat(end <= png.length, 'Truncated badge PNG data');
    requireThat(crc32(png.subarray(offset + 4, end - 4)) === png.readUInt32BE(end - 4), 'Badge PNG chunk checksum differs');
    if (offset === 8) requireThat(type === 'IHDR', 'Badge PNG has no IHDR');
    if (type === 'IHDR') {
      requireThat(offset === 8 && length === 13, 'Invalid badge PNG IHDR');
      width = png.readUInt32BE(offset + 8); height = png.readUInt32BE(offset + 12);
      // ponytail: the approved badge is RGBA8 without interlacing; extend only for a redesigned asset.
      requireThat(width > 0 && height > 0 && width * height <= 4_000_000 &&
        png.subarray(offset + 16, offset + 21).equals(Buffer.from([8, 6, 0, 0, 0])), 'Unsupported badge PNG dimensions/format');
    } else if (type === 'IDAT') compressed.push(png.subarray(offset + 8, end - 4));
    else if (type === 'IEND') {
      requireThat(length === 0 && end === png.length, 'Invalid badge PNG ending');
      ended = true;
    } else requireThat(/^[a-z]/.test(type) || type === 'PLTE', 'Unknown critical badge PNG chunk');
    offset = end;
  }
  requireThat(ended && compressed.length > 0, 'Incomplete badge PNG');
  const stride = width * 4 + 1, expected = stride * height;
  const pixels = inflateSync(Buffer.concat(compressed), { maxOutputLength: expected });
  requireThat(pixels.length === expected, 'Badge PNG pixel data is truncated');
  for (let row = 0; row < height; row++) requireThat(pixels[row * stride] <= 4, 'Invalid badge PNG row filter');
}

export async function verifyReadmes(root = ROOT) {
  const base = await realpath(root);
  const read = async (path, limit = META_LIMIT) => {
    const absolute = await realpath(resolve(base, path));
    requireThat(absolute.startsWith(`${base}${sep}`), 'Local asset escapes checkout');
    const info = await stat(absolute);
    requireThat(info.isFile() && info.size > 0 && info.size <= limit, `Invalid local file: ${path}`);
    return readFile(absolute);
  };
  const config = json(await read('.github/family-page.json'), 'Family page');
  requireThat(config.owner === 'zarubinvibe' && config.slug === 'iriz', 'Unexpected family page repository');
  const downloads = config.application?.downloads;
  requireThat(Array.isArray(downloads) && downloads.length === 1 && downloads[0].id === 'macos-arm64' &&
    downloads[0].kind === 'direct' && downloads[0].url === STABLE, 'Application download configuration differs');
  const badge = downloads[0].badge;
  requireThat(badge && /^docs\/assets\/(?:[a-zA-Z0-9_-]+\/)*[a-zA-Z0-9_-]+\.png$/.test(badge.path) && HASH.test(badge.sha256) && badge.width === 180, 'Invalid application badge configuration');
  const png = await read(badge.path, 8 * META_LIMIT);
  requireThat(sha256(png) === badge.sha256, 'Application badge hash differs');
  validateBadgePNG(png);
  for (const [filename, heading] of LOCALES)
    validateReadme((await read(filename)).toString('utf8'), filename, heading, badge.path);
  return LOCALES.map(([filename]) => filename);
}

async function main() {
  const args = process.argv.slice(2);
  assert(args.length <= 1 && (!args.length || ['--selftest', '--local'].includes(args[0])), 'Usage: node scripts/check_app_download.mjs [--selftest|--local]');
  if (args[0] === '--selftest') return (await import('./check_app_download_test.mjs')).selftest();
  const readmes = await verifyReadmes();
  console.log(`PASS: application download CTA in ${readmes.join(', ')}`);
  if (args[0] === '--local') return;
  console.log('Checking the public release anonymously (maximum 10 minutes).');
  const result = await verifyRelease();
  console.log(`PASS: v${result.version}, ${result.bytes} bytes per DMG, SHA-256 ${result.sha256}, source ${result.source_sha}`);
  console.log('Download integrity verified. macOS installation, signature, permissions and dictation require separate checks.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href)
  main().catch(error => { console.error(`FAIL: ${error.message}`); process.exitCode = 1; });
