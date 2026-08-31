'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const { assetFor, checksumFor, install } = require('../install.cjs');

const binary = Buffer.from('native-hypertask-binary');
const digest = crypto.createHash('sha256').update(binary).digest('hex');

function releaseServer(checksum = digest, stallBinary = false) {
  const server = http.createServer((request, response) => {
    if (request.url === '/download/v0.2.0/hypertask-linux-x86_64') {
      if (!stallBinary) response.end(binary);
      return;
    }
    if (request.url === '/download/v0.2.0/checksums.txt') {
      response.end(`${checksum}  hypertask-linux-x86_64\n`);
      return;
    }
    response.writeHead(404).end();
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => {
      const address = server.address();
      resolve({ server, root: `http://127.0.0.1:${address.port}` });
    });
  });
}

test('maps every released platform to its native binary', () => {
  assert.equal(assetFor('linux', 'x64'), 'hypertask-linux-x86_64');
  assert.equal(assetFor('linux', 'arm64'), 'hypertask-linux-aarch64');
  assert.equal(assetFor('darwin', 'x64'), 'hypertask-macos-x86_64');
  assert.equal(assetFor('darwin', 'arm64'), 'hypertask-macos-aarch64');
  assert.equal(assetFor('win32', 'x64'), 'hypertask-windows-x86_64.exe');
  assert.throws(() => assetFor('win32', 'arm64'), /Unsupported platform/);
});

test('finds only the requested release checksum', () => {
  const checksums = `${'a'.repeat(64)}  other\n${digest}  hypertask-linux-x86_64\n`;
  assert.equal(checksumFor(checksums, 'hypertask-linux-x86_64'), digest);
  assert.throws(() => checksumFor(checksums, 'missing'), /No checksum/);
});

test('installs a checksum-verified native binary', async (t) => {
  const { server, root } = await releaseServer();
  t.after(() => server.close());
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'hypertask-npm-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const destination = path.join(directory, 'hypertask.exe');

  const options = {
    platform: 'linux',
    architecture: 'x64',
    releaseRoot: root,
    destination,
  };
  const [result] = await Promise.all([install(options), install(options)]);

  assert.equal(result.asset, 'hypertask-linux-x86_64');
  assert.deepEqual(await fs.readFile(destination), binary);
  if (process.platform !== 'win32') {
    assert.notEqual((await fs.stat(destination)).mode & 0o111, 0);
  }
});

test('rejects a binary whose checksum does not match', async (t) => {
  const { server, root } = await releaseServer('0'.repeat(64));
  t.after(() => server.close());
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'hypertask-npm-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));

  await assert.rejects(
    install({
      platform: 'linux',
      architecture: 'x64',
      releaseRoot: root,
      destination: path.join(directory, 'hypertask.exe'),
    }),
    /Checksum verification failed/,
  );
});

test('times out a stalled release download', async (t) => {
  const { server, root } = await releaseServer(digest, true);
  t.after(() => server.close());
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'hypertask-npm-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));

  await assert.rejects(
    install({
      platform: 'linux',
      architecture: 'x64',
      releaseRoot: root,
      destination: path.join(directory, 'hypertask.exe'),
      timeoutMs: 20,
    }),
    (error) => ['AbortError', 'TimeoutError'].includes(error.name),
  );
});
