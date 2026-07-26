import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const [artifactArgument, architecture, version, manifestArgument] = process.argv.slice(2);
if (!artifactArgument || !manifestArgument
  || !['x64', 'arm64'].includes(architecture)
  || !/^\d+\.\d+\.\d+$/.test(version ?? '')) {
  console.error(
    'Usage: node write-release-manifest.mjs <artifact> <x64|arm64> <version> <manifest>'
  );
  process.exit(2);
}

const artifactPath = path.resolve(artifactArgument);
const manifestPath = path.resolve(manifestArgument);
const contents = fs.readFileSync(artifactPath);
const manifest = {
  version,
  filename: path.basename(artifactPath),
  sha256: crypto.createHash('sha256').update(contents).digest('hex'),
  size_bytes: contents.length,
  notes: `Windows ${architecture} release`,
  published_at: new Date().toISOString(),
  architecture
};

fs.mkdirSync(path.dirname(manifestPath), { recursive: true });
fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`, {
  encoding: 'utf8',
  mode: 0o644
});
