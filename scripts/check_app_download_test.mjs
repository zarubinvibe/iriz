import assert from 'node:assert/strict';
import { chmod, cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { crc32, deflateSync } from 'node:zlib';
import { API, DOWNLOAD, STABLE, sha256, trustedURL, request, releaseSnapshot,
  checksums, validateManifest, validateReadme, validateBadgePNG, verifyRelease,
  verifyDownloadedNative, verifyDownloadedRelease, UI_SHOT_NAMES } from './check_app_download.mjs';

const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

async function downloadedFixture(work) {
  const root = await mkdtemp(join(tmpdir(), 'iriz-downloaded-release-test-'));
  const version = '9.8.7', source = 'a'.repeat(40), token = 'receipt-token-123456';
  const images = [`iriz-${version}-arm64.dmg`, 'iriz-macos-arm64.dmg'];
  const dmg = Buffer.from('synthetic identical dmg bytes');
  const manifest = {
    version, source_sha: source, source_dirty: false, notarized: false,
    signing: { mode: 'ad-hoc', identity: '-' },
    artifacts: images.map(file => ({
      file, bytes: dmg.length, sha256: sha256(dmg), architectures: ['arm64'],
    })),
  };
  const files = new Map(images.map(name => [name, dmg]));
  files.set('release-manifest.json', Buffer.from(JSON.stringify(manifest)));
  files.set('SHA256SUMS.txt', Buffer.from([...files]
    .map(([name, bytes]) => `${sha256(bytes)}  ${name}\n`).join('')));
  for (const [name, bytes] of files) await writeFile(join(root, name), bytes);
  const writeChecksums = async () => {
    const bytes = Buffer.from([...files].filter(([name]) => name !== 'SHA256SUMS.txt')
      .map(([name, value]) => `${sha256(value)}  ${name}\n`).join(''));
    files.set('SHA256SUMS.txt', bytes);
    await writeFile(join(root, 'SHA256SUMS.txt'), bytes);
  };
  const writeManifest = async value => {
    const bytes = Buffer.from(JSON.stringify(value));
    files.set('release-manifest.json', bytes);
    await writeFile(join(root, 'release-manifest.json'), bytes);
    await writeChecksums();
  };
  const environment = {
    PRODUCT_RELEASE_ASSET_DIR: root,
    PRODUCT_RELEASE_VERSION: version,
    PRODUCT_RELEASE_TAG: `v${version}`,
    PRODUCT_RELEASE_SOURCE_SHA: source,
    PRODUCT_RELEASE_VERIFY_TOKEN: token,
    PRODUCT_RELEASE_STAGE: 'draft',
  };
  try { return await work({ root, environment, manifest, files, images, token, writeChecksums, writeManifest }); }
  finally { await rm(root, { recursive: true, force: true }); }
}

function nativeFixtureRunner({ failCodesign = false, minimumOS = '14.0', shotNames = UI_SHOT_NAMES } = {}) {
  const calls = [];
  const run = async (command, args, options = {}) => {
    calls.push([command, ...args]);
    assert.equal(options.env.GH_TOKEN, undefined);
    assert.equal(options.env.HOME, options.env.CFFIXED_USER_HOME);
    if (command === '/usr/bin/hdiutil' && args[0] === 'attach') {
      const mount = args[args.indexOf('-mountpoint') + 1];
      const resources = join(mount, 'iriz.app', 'Contents', 'Resources');
      const meeting = join(resources, 'IrizApp_IrizDictate.bundle', 'MeetingMinutes');
      const executable = join(mount, 'iriz.app', 'Contents', 'MacOS', 'iriz');
      await mkdir(join(resources, 'IrizApp_IrizCore.bundle'), { recursive: true });
      await mkdir(join(executable, '..'), { recursive: true });
      await writeFile(executable, 'synthetic executable');
      await writeFile(join(mount, 'iriz.app', 'Contents', 'Info.plist'), 'synthetic plist');
      await chmod(executable, 0o755);
      await symlink('/Applications', join(mount, 'Applications'));
      await cp(new URL('../Sources/IrizDictate/Resources/MeetingMinutes', import.meta.url), meeting,
        { recursive: true });
    }
    if (command === '/usr/bin/plutil') return {
      stdout: `${args.includes('LSMinimumSystemVersion') ? minimumOS : '9.8.7'}\n`, stderr: '',
    };
    if (command === '/usr/bin/lipo') return { stdout: 'arm64\n', stderr: '' };
    if (command === '/usr/bin/codesign' && args[0] === '-dv') {
      if (failCodesign) throw new Error('synthetic codesign failure');
      return { stdout: '', stderr: 'Signature=adhoc\nTeamIdentifier=not set\n' };
    }
    if (command === '/usr/bin/ditto') await cp(args[0], args[1], { recursive: true });
    if (args[0] === '--export-ui-shots') {
      assert.equal(options.cwd, options.env.HOME);
      for (const name of shotNames) await writeFile(join(args[1], name), PNG_SIGNATURE);
    }
    return { stdout: '', stderr: '' };
  };
  return { calls, run };
}

function fixture() {
  const version = '9.8.7';
  const source = 'a'.repeat(40);
  const dmg = Buffer.alloc(768, 7);
  dmg.write('koly', dmg.length - 512);
  const images = [`iriz-${version}-arm64.dmg`, 'iriz-macos-arm64.dmg'];
  const manifest = { version, source_sha: source, source_dirty: false,
    artifacts: images.map(file => ({ file, bytes: dmg.length, sha256: sha256(dmg), architectures: ['arm64'] })) };
  const files = new Map(images.map(name => [name, dmg]));
  files.set('release-manifest.json', Buffer.from(JSON.stringify(manifest)));
  files.set('SHA256SUMS.txt', Buffer.from([...files].map(([name, bytes]) => `${sha256(bytes)}  ${name}\n`).join('')));
  const release = { id: 123, tag_name: `v${version}`, draft: false, prerelease: false,
    assets: [...files].map(([name, bytes], index) => ({ name, id: index + 1, state: 'uploaded',
      size: bytes.length, digest: `sha256:${sha256(bytes)}`, browser_download_url: `${DOWNLOAD}/download/v${version}/${name}` })) };
  const calls = [];
  let latestReads = 0;
  const data = { files, release, manifest, calls, source, version, changeLatest: false, annotated: false };
  data.fetchImpl = async (url, options) => {
    calls.push(url);
    assert.equal(options.credentials, 'omit');
    assert.equal(options.redirect, 'manual');
    assert.equal(options.headers.Authorization, undefined);
    assert.equal(options.headers.Cookie, undefined);
    assert.equal(options.headers['Accept-Encoding'], 'identity');
    const response = bytes => new Response(bytes, { headers: { 'content-length': String(Buffer.byteLength(bytes)) } });
    const json = object => response(JSON.stringify(object));
    if (url === `${API}/releases/latest`) {
      latestReads++;
      return json(data.changeLatest && latestReads > 1 ? { ...release, id: 124 } : release);
    }
    if (url === `${API}/git/ref/tags/v${version}`) return json({ ref: `refs/tags/v${version}`,
      object: { type: data.annotated ? 'tag' : 'commit', sha: data.annotated ? 'b'.repeat(40) : source } });
    if (url === `${API}/git/tags/${'b'.repeat(40)}`) return json({ sha: 'b'.repeat(40), object: { type: 'commit', sha: source } });
    if (url === `${API}/commits/${source}`) return json({ sha: source });
    if (url === STABLE) return new Response(null, { status: 302,
      headers: { location: `${DOWNLOAD}/download/v${version}/iriz-macos-arm64.dmg` } });
    if (url.startsWith(`${DOWNLOAD}/download/v${version}/`)) return new Response(null, { status: 302,
      headers: { location: `https://release-assets.githubusercontent.com/fixture/${url.split('/').at(-1)}?signature=private-in-logs` } });
    if (url.startsWith('https://release-assets.githubusercontent.com/fixture/')) {
      const name = new URL(url).pathname.split('/').at(-1);
      const body = files.get(name);
      return body ? response(body) : new Response(null, { status: 404 });
    }
    throw new Error(`Unexpected fixture URL: ${url}`);
  };
  return data;
}

export async function selftest() {
  let passed = 0;
  const test = async (name, work) => {
    try { await work(); passed++; }
    catch (error) { throw new Error(`Selftest ${name}: ${error.message}`); }
  };
  const run = data => verifyRelease({ fetchImpl: data.fetchImpl, retryDelayMs: 0 });
  const reject = async (data, pattern) => assert.rejects(() => run(data), pattern);
  const responseOptions = body => ({ fetchImpl: async () => new Response(body), attempts: 1, retryDelayMs: 0 });

  await test('complete anonymous release', async () => {
    const data = fixture(), result = await run(data);
    assert.equal(result.version, data.version);
    assert.equal(result.bytes, 768);
    assert.equal(result.source_sha, data.source);
    assert.equal(data.calls.filter(url => url === `${API}/releases/latest`).length, 2);
    assert(data.calls.includes(STABLE));
  });
  await test('annotated tag', async () => { const data = fixture(); data.annotated = true; await run(data); });
  await test('network retry recovers', async () => {
    let calls = 0;
    const result = await request(STABLE, { retryDelayMs: 0, fetchImpl: async () => {
      if (++calls === 1) throw new Error('offline');
      return new Response('ok');
    } });
    assert.equal(result.bytes, 2); assert.equal(calls, 2);
  });
  await test('network retry bounded', async () => {
    let calls = 0;
    await assert.rejects(() => request(STABLE, { retryDelayMs: 0, fetchImpl: async () => { calls++; throw new Error('offline'); } }), /network request failed/);
    assert.equal(calls, 2);
  });
  await test('HTTP retry bounded', async () => {
    let calls = 0;
    await assert.rejects(() => request(STABLE, { retryDelayMs: 0,
      fetchImpl: async () => { calls++; return new Response(null, { status: 503 }); } }), /503/);
    assert.equal(calls, 2);
  });
  await test('rate limit is not green', async () => {
    await assert.rejects(() => request(STABLE, { fetchImpl: async () => new Response(null,
      { status: 403, headers: { 'x-ratelimit-remaining': '0' } }) }), /rate limit exhausted/);
  });
  await test('request timeout', async () => {
    await assert.rejects(() => request(STABLE, { attempts: 1, timeoutMs: 5,
      fetchImpl: (_url, options) => new Promise((_resolve, rejectPromise) => options.signal.addEventListener('abort', () => rejectPromise(new Error('abort')))) }), /timed out/);
  });
  await test('stalled response body timeout', async () => {
    await assert.rejects(() => request(STABLE, { attempts: 1, timeoutMs: 5,
      fetchImpl: async (_url, options) => new Response(new ReadableStream({ start(controller) {
        options.signal.addEventListener('abort', () => controller.error(new Error('aborted')));
      } })) }), /body timed out/);
  });
  await test('run deadline', async () => assert.rejects(() => request(STABLE, {
    deadline: Date.now() - 1, fetchImpl: async () => { throw new Error('must not fetch'); } }), /deadline exceeded/));
  await test('untrusted URL boundaries', () => {
    for (const url of ['http://github.com/test', 'https://github.com.evil.test/', 'https://127.0.0.1/',
      'https://[::1]/', 'https://169.254.169.254/', 'https://github.com:444/',
      'https://user:password@github.com/', 'https://evil.test/', 'file:///tmp/file', 'https://github.com/#token'])
      assert.throws(() => trustedURL(url), /Untrusted/);
  });
  await test('unsafe redirects never fetched', async () => {
    let calls = 0;
    await assert.rejects(() => request(STABLE, { fetchImpl: async () => {
      calls++; return new Response(null, { status: 302, headers: { location: 'https://127.0.0.1/metadata' } });
    } }), /Untrusted/);
    assert.equal(calls, 1);
  });
  await test('redirect loop bounded', async () => {
    let calls = 0;
    await assert.rejects(() => request(STABLE, { fetchImpl: async () => { calls++;
      return new Response(null, { status: 302, headers: { location: STABLE } }); } }), /Too many/);
    assert.equal(calls, 6);
  });
  await test('missing redirect location', async () => assert.rejects(() => request(STABLE,
    { fetchImpl: async () => new Response(null, { status: 302 }) }), /no Location/));
  await test('HTML 200 without MIME', async () => assert.rejects(() => request(STABLE,
    responseOptions('<!doctype html><html>error</html>')), /HTML/));
  await test('HTML 200 MIME', async () => assert.rejects(() => request(STABLE,
    { fetchImpl: async () => new Response('arbitrary', { headers: { 'content-type': 'text/html' } }) }), /HTML/));
  await test('empty response', async () => assert.rejects(() => request(STABLE, responseOptions('')), /Empty/));
  await test('truncated body', async () => assert.rejects(() => request(STABLE,
    { fetchImpl: async () => new Response('short', { headers: { 'content-length': '10' } }) }), /Truncated/));
  await test('body exceeds size limit', async () => assert.rejects(() => request(STABLE,
    { ...responseOptions('overflow'), maxBytes: 4 }), /size limit/));
  await test('oversized headers', async () => assert.rejects(() => request(STABLE,
    { maxBytes: 4, fetchImpl: async () => new Response('x', { headers: { 'content-length': '5' } }) }), /oversized/));
  await test('expected asset size mismatch', async () => assert.rejects(() => request(STABLE,
    { ...responseOptions('short'), expectedBytes: 10 }), /size differs/));
  await test('corrupt DMG trailer', async () => assert.rejects(() => request(STABLE,
    { ...responseOptions(Buffer.alloc(768)), dmg: true }), /DMG trailer/));
  await test('interrupted body', async () => assert.rejects(() => request(STABLE,
    { fetchImpl: async () => new Response(new ReadableStream({ start(controller) { controller.error(new Error('stream interrupted')); } })) }), /stream interrupted/));
  await test('empty release asset list', () => { const data = fixture(); data.release.assets = []; assert.throws(() => releaseSnapshot(data.release), /filenames/); });
  await test('unexpected release asset', () => { const data = fixture(); data.release.assets[0].name = '../other.dmg'; assert.throws(() => releaseSnapshot(data.release), /filenames/); });
  await test('duplicate release asset', () => { const data = fixture(); data.release.assets[0] = data.release.assets[1]; assert.throws(() => releaseSnapshot(data.release), /filenames/); });
  await test('missing GitHub digest', () => { const data = fixture(); data.release.assets[0].digest = null; assert.throws(() => releaseSnapshot(data.release), /digest/); });
  await test('metadata cannot choose another host', () => { const data = fixture(); data.release.assets[0].browser_download_url = 'https://evil.test/a'; assert.throws(() => releaseSnapshot(data.release), /Unexpected asset URL/); });
  await test('missing file', async () => { const data = fixture(); data.files.delete('iriz-macos-arm64.dmg'); await reject(data, /404/); });
  await test('wrong digest', async () => {
    const data = fixture(), copy = Buffer.from(data.files.get('iriz-macos-arm64.dmg'));
    copy[0] ^= 1; data.files.set('iriz-macos-arm64.dmg', copy); await reject(data, /SHA-256 mismatch/);
  });
  await test('stable resolves to wrong version', async () => {
    const data = fixture(), original = data.fetchImpl;
    data.fetchImpl = (url, options) => url === STABLE ? new Response(null, { status: 302,
      headers: { location: 'https://release-assets.githubusercontent.com/fixture/iriz-macos-arm64.dmg' } }) : original(url, options);
    await reject(data, /another release/);
  });
  await test('latest changed mid-download', async () => { const data = fixture(); data.changeLatest = true; await reject(data, /Latest release changed/); });
  await test('checksums reject malicious names and duplicates', () => {
    for (const text of ['', `${'a'.repeat(64)}  ../file\n`, `${'a'.repeat(64)}  $(touch_file)\n`, `${'a'.repeat(64)}  good\n${'a'.repeat(64)}  good\n`])
      assert.throws(() => checksums(Buffer.from(text), ['good']), /filename/);
  });
  await test('manifest wrong version and dirty source', () => {
    const data = fixture(), snapshot = releaseSnapshot(data.release);
    assert.throws(() => validateManifest({ ...data.manifest, version: '0.0.0' }, snapshot, new Map()), /version\/source/);
    assert.throws(() => validateManifest({ ...data.manifest, source_dirty: true }, snapshot, new Map()), /version\/source/);
  });
  await test('downloaded release emits receipt only after native verification', () => downloadedFixture(async data => {
    let probed = false;
    const receipt = await verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: async () => { probed = true; } });
    assert.equal(probed, true);
    assert.equal(receipt, `PRODUCT_RELEASE_VERIFIED=${data.token}`);
  }));
  await test('downloaded release refuses invalid receipt token', () => downloadedFixture(async data => {
    data.environment.PRODUCT_RELEASE_VERIFY_TOKEN = '';
    await assert.rejects(() => verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: async () => assert.fail('native probe must not run') }), /verify token/);
  }));
  await test('downloaded release refuses invalid stage', () => downloadedFixture(async data => {
    data.environment.PRODUCT_RELEASE_STAGE = 'published';
    await assert.rejects(() => verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: async () => assert.fail('native probe must not run') }), /stage/);
  }));
  await test('downloaded release refuses manifest contract drift', () => downloadedFixture(async data => {
    await data.writeManifest({ ...data.manifest, source_dirty: true });
    await assert.rejects(() => verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: async () => assert.fail('native probe must not run') }), /manifest version\/source/);
    await data.writeManifest({ ...data.manifest, signing: { mode: 'self-signed', identity: 'local' } });
    await assert.rejects(() => verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: async () => assert.fail('native probe must not run') }), /required ad-hoc/);
  }));
  await test('downloaded release refuses checksum mismatch', () => downloadedFixture(async data => {
    const bad = Buffer.from(data.files.get('SHA256SUMS.txt').toString().replace(/^[a-f0-9]{64}/, '0'.repeat(64)));
    await writeFile(join(data.root, 'SHA256SUMS.txt'), bad);
    await assert.rejects(() => verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: async () => assert.fail('native probe must not run') }), /SHA256SUMS mismatch/);
  }));
  await test('downloaded release propagates native probe failure without receipt', () => downloadedFixture(async data => {
    await assert.rejects(() => verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: async () => { throw new Error('synthetic hdiutil failure'); } }), /synthetic hdiutil failure/);
  }));
  await test('downloaded native probe uses readonly mount and clean launch smoke', () => downloadedFixture(async data => {
    const native = nativeFixtureRunner();
    const receipt = await verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: input => verifyDownloadedNative({ ...input, run: native.run }) });
    assert.equal(receipt, `PRODUCT_RELEASE_VERIFIED=${data.token}`);
    assert.equal(native.calls.filter(call => call[0] === '/usr/bin/hdiutil' && call[1] === 'verify').length, 2);
    assert(native.calls.some(call => call[0] === '/usr/bin/hdiutil' && call[1] === 'attach' &&
      call.includes('-readonly') && call.includes('-nobrowse') && call.includes('-noautoopen')));
    assert(native.calls.some(call => call[0] === '/usr/bin/lipo' && call[1] === '-archs'));
    assert.equal(native.calls.filter(call => call[0] === '/usr/bin/codesign' && call[1] === '--verify').length, 2);
    assert(native.calls.some(call => call[0] === '/usr/bin/ditto'));
    const detach = native.calls.findIndex(call => call[0] === '/usr/bin/hdiutil' && call[1] === 'detach');
    const launch = native.calls.findIndex(call => call[1] === '--export-ui-shots');
    assert(detach >= 0 && launch > detach && native.calls[launch][0].includes('/iriz.app/Contents/MacOS/iriz'));
  }));
  await test('downloaded native probe requires macOS 14', () => downloadedFixture(async data => {
    const native = nativeFixtureRunner({ minimumOS: '13.0' });
    await assert.rejects(() => verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: input => verifyDownloadedNative({ ...input, run: native.run }) }), /minimum macOS/);
    assert.equal(native.calls.at(-1)[0], '/usr/bin/hdiutil');
    assert.equal(native.calls.at(-1)[1], 'detach');
  }));
  await test('downloaded native probe requires every expected UI shot', () => downloadedFixture(async data => {
    const native = nativeFixtureRunner({ shotNames: UI_SHOT_NAMES.slice(1) });
    await assert.rejects(() => verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: input => verifyDownloadedNative({ ...input, run: native.run }) }), /UI shots/);
  }));
  await test('downloaded native probe detaches after mounted check failure', () => downloadedFixture(async data => {
    const native = nativeFixtureRunner({ failCodesign: true });
    await assert.rejects(() => verifyDownloadedRelease({ environment: data.environment,
      nativeProbe: input => verifyDownloadedNative({ ...input, run: native.run }) }), /synthetic codesign failure/);
    assert.equal(native.calls.at(-1)[0], '/usr/bin/hdiutil');
    assert.equal(native.calls.at(-1)[1], 'detach');
    assert(!native.calls.some(call => call[1] === '--export-ui-shots'));
  }));
  const badge = 'docs/assets/download-macos.png';
  const block = `<!-- application-downloads:start -->\n<a href="${STABLE}"><img src="${badge}" alt="Download for macOS" width="180"></a>\n[Download](${STABLE})\n<!-- application-downloads:end -->`;
  const readme = `# iriz\n\n## Contents\n\n${block}\n\n## What This Is\n`;
  await test('README badge after Contents and before What', () => validateReadme(readme, 'README.md', 'What This Is', badge));
  await test('README badge missing', () => assert.throws(() => validateReadme(readme.replace('<img', '<span'), 'README.md', 'What This Is', badge), /badge/));
  await test('README wrong href', () => assert.throws(() => validateReadme(readme.replace(`href="${STABLE}"`, 'href="https://example.com"'), 'README.md', 'What This Is', badge), /badge/));
  await test('README badge below What', () => assert.throws(() => validateReadme(`\n## What This Is\n${block}`, 'README.md', 'What This Is', badge), /precede/));
  await test('README obsolete CTA', () => assert.throws(() => validateReadme(`${readme}\n[![Download](https://img.shields.io/badge/download)](${STABLE})`, 'README.md', 'What This Is', badge), /obsolete/));
  await test('README commented badge', () => assert.throws(() => validateReadme(readme.replace('<a href', '<!-- <a href').replace('</a>', '</a> -->'), 'README.md', 'What This Is', badge), /badge/));
  await test('README whole block commented out', () => assert.throws(() => validateReadme(readme.replace(block, `<!-- hidden\n${block}\n-->`), 'README.md', 'What This Is', badge), /block required/));
  await test('README whole block inside code fence', () => assert.throws(() => validateReadme(readme.replace(block, `\`\`\`html\n${block}\n\`\`\``), 'README.md', 'What This Is', badge), /block required/));
  await test('README unclosed code fence', () => assert.throws(() => validateReadme(readme.replace(block, `\`\`\`html\n${block}`), 'README.md', 'What This Is', badge), /block required/));
  await test('README indented code', () => assert.throws(() => validateReadme(readme.replace(block, block.split('\n').map(line => `    ${line}`).join('\n')), 'README.md', 'What This Is', badge), /block required/));
  await test('README preformatted block', () => assert.throws(() => validateReadme(readme.replace(block, `<pre>\n${block}\n</pre>`), 'README.md', 'What This Is', badge), /block required/));
  await test('README badge width zero', () => assert.throws(() => validateReadme(readme.replace('width="180"', 'width="0"'), 'README.md', 'What This Is', badge), /width/));
  await test('README data attributes are not links', () => assert.throws(() => validateReadme(readme.replace('href=', 'data-href='), 'README.md', 'What This Is', badge), /badge/));
  await test('README data source is not an image', () => assert.throws(() => validateReadme(readme.replace('src=', 'data-src='), 'README.md', 'What This Is', badge), /image/));
  await test('README badge before Contents', () => assert.throws(() => validateReadme(`# iriz\n${block}\n## Contents\n\n## What This Is\n`, 'README.md', 'What This Is', badge), /follow Contents/));
  const pngChunk = (name, bytes) => {
    const result = Buffer.alloc(bytes.length + 12);
    result.writeUInt32BE(bytes.length); result.write(name, 4); bytes.copy(result, 8);
    result.writeUInt32BE(crc32(result.subarray(4, result.length - 4)), result.length - 4);
    return result;
  };
  const pngHeader = PNG_SIGNATURE;
  const ihdr = Buffer.from([0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]);
  const png = Buffer.concat([pngHeader, pngChunk('IHDR', ihdr), pngChunk('IDAT', deflateSync(Buffer.alloc(5))), pngChunk('IEND', Buffer.alloc(0))]);
  await test('valid badge PNG', () => validateBadgePNG(png));
  await test('PNG signature alone is not an image', () => assert.throws(() => validateBadgePNG(pngHeader), /Incomplete/));
  await test('truncated PNG', () => assert.throws(() => validateBadgePNG(png.subarray(0, -1)), /Truncated/));
  await test('PNG CRC differs', () => {
    const broken = Buffer.from(png); broken[20] ^= 1;
    assert.throws(() => validateBadgePNG(broken), /checksum/);
  });
  await test('PNG missing pixels', () => assert.throws(() => validateBadgePNG(Buffer.concat([
    pngHeader, pngChunk('IHDR', ihdr), pngChunk('IDAT', deflateSync(Buffer.alloc(1))), pngChunk('IEND', Buffer.alloc(0)),
  ])), /pixel data/));
  await test('workflow stays public and read-only', async () => {
    const workflow = await readFile(new URL('../.github/workflows/app-download.yml', import.meta.url), 'utf8');
    assert.match(workflow, /github\.repository == 'zarubinvibe\/iriz' && github\.event\.repository\.visibility == 'public'/);
    assert.match(workflow, /contents: read/);
    assert.match(workflow, /persist-credentials: false/);
    assert.match(workflow, /runs-on: ubuntu-24\.04/);
    assert.match(workflow, /timeout-minutes: 15/);
    assert.doesNotMatch(workflow, /contents: write|GH_TOKEN|GITHUB_TOKEN|secrets\.|schedule:|pull_request_target:/);
  });
  console.log(`PASS: ${passed} offline app-download checks`);
}
