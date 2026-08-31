'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');

const BINARY_VERSION = '0.2.0';
const RELEASE_ROOT = 'https://github.com/hypertask-ai/cli/releases';

function assetFor(platform, architecture) {
  const assets = {
    'linux:x64': 'hypertask-linux-x86_64',
    'linux:arm64': 'hypertask-linux-aarch64',
    'darwin:x64': 'hypertask-macos-x86_64',
    'darwin:arm64': 'hypertask-macos-aarch64',
    'win32:x64': 'hypertask-windows-x86_64.exe',
  };
  const asset = assets[`${platform}:${architecture}`];
  if (!asset) throw new Error(`Unsupported platform: ${platform} ${architecture}`);
  return asset;
}

async function download(url) {
  const response = await fetch(url, { redirect: 'follow' });
  if (!response.ok) throw new Error(`Download failed with HTTP ${response.status}: ${url}`);
  return Buffer.from(await response.arrayBuffer());
}

function checksumFor(checksums, asset) {
  for (const line of checksums.split(/\r?\n/)) {
    const match = line.match(/^([a-f0-9]{64})\s+\*?(.+)$/i);
    if (match && match[2] === asset) return match[1].toLowerCase();
  }
  throw new Error(`No checksum found for ${asset}`);
}

async function install(options = {}) {
  const platform = options.platform || process.platform;
  const architecture = options.architecture || process.arch;
  const version = options.version || BINARY_VERSION;
  const releaseRoot = options.releaseRoot || process.env.HYPERTASK_CLI_RELEASE_ROOT || RELEASE_ROOT;
  const destination = options.destination || path.join(__dirname, 'bin', 'hypertask.exe');
  const asset = assetFor(platform, architecture);
  const baseUrl = `${releaseRoot}/download/v${version}`;
  const [binary, checksums] = await Promise.all([
    download(`${baseUrl}/${asset}`),
    download(`${baseUrl}/checksums.txt`).then((value) => value.toString('utf8')),
  ]);
  const expected = checksumFor(checksums, asset);
  const actual = crypto.createHash('sha256').update(binary).digest('hex');
  if (actual !== expected) throw new Error(`Checksum verification failed for ${asset}`);

  await fs.mkdir(path.dirname(destination), { recursive: true });
  const temporary = `${destination}.${process.pid}.tmp`;
  await fs.writeFile(temporary, binary, { mode: 0o755 });
  await fs.chmod(temporary, 0o755);
  try {
    await fs.rename(temporary, destination);
  } catch (error) {
    if (!['EEXIST', 'EPERM'].includes(error.code)) throw error;
    await fs.rm(destination, { force: true });
    await fs.rename(temporary, destination);
  }
  return { asset, destination };
}

if (require.main === module) {
  install()
    .then(({ destination }) => console.log(`Installed native Hypertask CLI at ${destination}`))
    .catch((error) => {
      console.error(`Failed to install native Hypertask CLI: ${error.message}`);
      process.exitCode = 1;
    });
}

module.exports = { BINARY_VERSION, assetFor, checksumFor, install };
