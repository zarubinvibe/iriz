#!/usr/bin/env node

import assert from 'node:assert/strict';
import { lstat, mkdir, readFile, writeFile } from 'node:fs/promises';
import { dirname, posix, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const REPOSITORY = 'zarubinvibe/iriz';
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const VERSION = /^\d+\.\d+\.\d+$/;

function usage(message) {
  throw new Error(`${message}\nUsage: node scripts/render_github_release_notes.mjs [--check] [--version X.Y.Z]`);
}

function options(argv) {
  let check = false;
  let selftest = false;
  let version;

  for (let index = 0; index < argv.length; index += 1) {
    switch (argv[index]) {
      case '--check': check = true; break;
      case '--selftest': selftest = true; break;
      case '--version':
        if (index + 1 >= argv.length) usage('--version needs a value.');
        version = argv[++index];
        break;
      default: usage(`Unknown argument: ${argv[index]}`);
    }
  }
  if (selftest && (check || version)) usage('--selftest cannot be combined with other arguments.');
  return { check, selftest, version };
}

function destination(value) {
  const leading = value.match(/^\s*/u)[0];
  const body = value.slice(leading.length);
  if (body.startsWith('<')) {
    const end = body.indexOf('>');
    if (end === -1) return null;
    return { path: body.slice(1, end), leading, trailing: body.slice(end + 1), brackets: true };
  }
  const match = body.match(/^(\S+)([\s\S]*)$/u);
  return match ? { path: match[1], leading, trailing: match[2], brackets: false } : null;
}

function relativeImage(path) {
  return path && !path.startsWith('/') && !path.startsWith('#') && !path.startsWith('//') &&
    !/^[A-Za-z][A-Za-z\d+.-]*:/u.test(path);
}

function escaped(text, index) {
  let slashes = 0;
  while (index > slashes && text[index - slashes - 1] === '\\') slashes += 1;
  return slashes % 2 === 1;
}

function rewriteLine(line, rewrite) {
  let cursor = 0;
  let output = '';
  while (cursor < line.length) {
    const start = line.indexOf('![', cursor);
    if (start === -1) return output + line.slice(cursor);
    if (escaped(line, start)) {
      output += line.slice(cursor, start + 2);
      cursor = start + 2;
      continue;
    }

    let opening = -1;
    for (let index = start + 2; index < line.length - 1; index += 1) {
      if (line[index] === ']' && line[index + 1] === '(' && !escaped(line, index)) {
        opening = index + 1;
        break;
      }
    }
    if (opening === -1) return output + line.slice(cursor);

    let depth = 1;
    let closing = -1;
    for (let index = opening + 1; index < line.length; index += 1) {
      if (escaped(line, index)) continue;
      if (line[index] === '(') depth += 1;
      if (line[index] === ')' && --depth === 0) {
        closing = index;
        break;
      }
    }
    if (closing === -1) throw new Error('Unclosed inline Markdown image.');

    const value = line.slice(opening + 1, closing);
    output += line.slice(cursor, opening + 1) + rewrite(value) + ')';
    cursor = closing + 1;
  }
  return output;
}

export function render(source, sourcePath, tag) {
  let rewrites = 0;
  let fence;
  const assets = new Set();
  const lines = source.match(/[^\r\n]*(?:\r\n|\n|$)/gu).filter(Boolean);

  const output = lines.map(line => {
    const marker = line.match(/^\s*(`{3,}|~{3,})/u)?.[1];
    if (marker) {
      if (!fence) fence = marker;
      else if (marker[0] === fence[0] && marker.length >= fence.length) fence = undefined;
      return line;
    }
    if (fence) return line;

    // ponytail: release notes use direct inline images; add a CommonMark parser only if that format grows.
    return rewriteLine(line, value => {
      const parsed = destination(value);
      if (!parsed || !relativeImage(parsed.path)) return value;

      const suffixIndex = parsed.path.search(/[?#]/u);
      const path = suffixIndex === -1 ? parsed.path : parsed.path.slice(0, suffixIndex);
      const suffix = suffixIndex === -1 ? '' : parsed.path.slice(suffixIndex);
      if (!path || path.includes('\\') || path.includes('%')) {
        throw new Error(`Unsupported relative image path: ${parsed.path}`);
      }
      const repositoryPath = posix.normalize(posix.join(posix.dirname(sourcePath), path));
      if (repositoryPath === '..' || repositoryPath.startsWith('../') || posix.isAbsolute(repositoryPath)) {
        throw new Error(`Image escapes repository root: ${parsed.path}`);
      }

      const prefix = `https://raw.githubusercontent.com/${REPOSITORY}/${tag}/`;
      const raw = prefix + repositoryPath.split('/').map(encodeURIComponent).join('/') + suffix;
      const rendered = parsed.brackets ? `<${raw}>` : raw;
      rewrites += 1;
      assets.add(repositoryPath);
      return `${parsed.leading}${rendered}${parsed.trailing}`;
    });
  }).join('');

  return { output, rewrites, assets: [...assets] };
}

async function verifyAssets(assets, root = ROOT, inspect = lstat) {
  for (const asset of assets) {
    const path = resolve(root, ...asset.split('/'));
    let info;
    try {
      info = await inspect(path);
    } catch {
      throw new Error(`Release-note image is missing: ${asset}`);
    }
    if (!info.isFile() || info.isSymbolicLink()) {
      throw new Error(`Release-note image is not a regular file: ${asset}`);
    }
  }
}

async function selftest() {
  const source = [
    '![hero](../assets/hero.png)',
    '[guide](../guide.md)',
    '![remote](https://example.com/hero.png)',
    '```md',
    '![example](../assets/example.png)',
    '```',
    ''
  ].join('\n');
  const result = render(source, 'docs/releases/v1.2.3.md', 'v1.2.3');
  assert.equal(result.rewrites, 1);
  assert.deepEqual(result.assets, ['docs/assets/hero.png']);
  assert.match(result.output, /raw\.githubusercontent\.com\/zarubinvibe\/iriz\/v1\.2\.3\/docs\/assets\/hero\.png/u);
  assert.match(result.output, /\[guide\]\(\.\.\/guide\.md\)/u);
  assert.match(result.output, /!\[remote\]\(https:\/\/example\.com\/hero\.png\)/u);
  assert.match(result.output, /!\[example\]\(\.\.\/assets\/example\.png\)/u);
  assert.throws(() => render('![bad](../../../secret.png)\n', 'docs/releases/v1.2.3.md', 'v1.2.3'), /escapes repository root/u);
  assert.throws(() => render('![bad](%2e%2e/%2fsecret.png)\n', 'docs/releases/v1.2.3.md', 'v1.2.3'), /Unsupported relative image path/u);
  assert.throws(() => render('![bad](safe(foo)/../../../../secret.png)\n', 'docs/releases/v1.2.3.md', 'v1.2.3'), /escapes repository root/u);
  await assert.rejects(verifyAssets(['docs/assets/missing.png'], '/repo', async () => { throw new Error('ENOENT'); }), /image is missing/u);
  console.log('render_github_release_notes: selftest passed');
}

async function main() {
  const args = options(process.argv.slice(2));
  if (args.selftest) return selftest();

  const version = args.version ?? (await readFile(resolve(ROOT, 'RELEASE_VERSION'), 'utf8')).trim();
  if (!VERSION.test(version)) usage(`Invalid version: ${version}`);

  const sourcePath = `docs/releases/v${version}.md`;
  const targetPath = `.github/release-notes/v${version}.md`;
  const source = await readFile(resolve(ROOT, sourcePath), 'utf8');
  const result = render(source, sourcePath, `v${version}`);
  if (result.rewrites === 0) throw new Error(`${sourcePath} has no relative Markdown image to publish.`);
  await verifyAssets(result.assets);

  const target = resolve(ROOT, targetPath);
  if (args.check) {
    const current = await readFile(target, 'utf8').catch(error => error.code === 'ENOENT' ? null : Promise.reject(error));
    if (current !== result.output) {
      throw new Error(`${targetPath} is stale. Run: node scripts/render_github_release_notes.mjs --version ${version}`);
    }
    console.log(`render_github_release_notes: ${targetPath} is current`);
    return;
  }

  await mkdir(dirname(target), { recursive: true });
  await writeFile(target, result.output, 'utf8');
  console.log(`render_github_release_notes: wrote ${targetPath}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => {
    console.error(`render_github_release_notes: ${error.message}`);
    process.exitCode = 1;
  });
}
