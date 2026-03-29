#!/usr/bin/env node

/**
 * Adapted from the upstream CodePush CLI implementation:
 * - shm-open/code-push-cli@4a5916d0144e9dd2cb4beacda186d76e888ff79e
 * - src/release-hooks/signing.ts
 * - src/lib/hash-utils.ts
 * - src/release-hooks/core-release.ts
 *
 * We keep the same package hashing/signing model, but stop before any server upload
 * so Bitrise can continue using its own upload API.
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { Buffer } = require('buffer');

const CURRENT_CLAIM_VERSION = '1.0.0';
const METADATA_FILE_NAME = '.codepushrelease';
const HASH_ALGORITHM = 'sha256';

const tempDir = process.env.TEMP_DIR;
const privateKeyPath = process.env.CODE_PUSH_PRIVATE_KEY_PATH;
const normalizedRootDir = process.env.CODE_PUSH_NORMALIZED_ROOT_DIR;

if (!tempDir || !privateKeyPath || !normalizedRootDir) {
  throw new Error(
    'TEMP_DIR, CODE_PUSH_PRIVATE_KEY_PATH, and CODE_PUSH_NORMALIZED_ROOT_DIR are required.',
  );
}

function normalizePath(filePath) {
  return filePath.replace(/\\/g, '/');
}

function isIgnored(relativeFilePath) {
  const __MACOSX = '__MACOSX/';
  const DS_STORE = '.DS_Store';
  const CODEPUSH_METADATA = '.codepushrelease';

  return (
    relativeFilePath.startsWith(__MACOSX) ||
    relativeFilePath === DS_STORE ||
    relativeFilePath.endsWith('/' + DS_STORE) ||
    relativeFilePath === CODEPUSH_METADATA ||
    relativeFilePath.endsWith('/' + CODEPUSH_METADATA)
  );
}

function hashFile(filePath) {
  const hash = crypto.createHash(HASH_ALGORITHM);
  hash.update(fs.readFileSync(filePath));
  return hash.digest('hex');
}

function copyDirectoryContents(sourceDir, destinationDir) {
  fs.mkdirSync(destinationDir, { recursive: true });

  for (const entry of fs.readdirSync(sourceDir, { withFileTypes: true })) {
    const sourcePath = path.join(sourceDir, entry.name);
    const destinationPath = path.join(destinationDir, entry.name);

    if (entry.isDirectory()) {
      copyDirectoryContents(sourcePath, destinationPath);
    } else {
      fs.copyFileSync(sourcePath, destinationPath);
    }
  }
}

function decodeJwtPayloadContentHash(jwt) {
  const parts = jwt.split('.');
  if (parts.length !== 3) {
    throw new Error('Generated .codepushrelease is not a valid JWT.');
  }

  const payload = JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
  if (!payload.contentHash) {
    throw new Error('Generated .codepushrelease JWT is missing contentHash.');
  }

  return payload.contentHash;
}

function resolvePackageSourceDir(rootDir) {
  const topLevelEntries = fs
    .readdirSync(rootDir, { withFileTypes: true })
    .filter((entry) => !['__MACOSX', '.DS_Store'].includes(entry.name));

  const codePushEntry = topLevelEntries.find(
    (entry) => entry.isDirectory() && entry.name === 'CodePush',
  );
  if (codePushEntry) {
    return path.join(rootDir, 'CodePush');
  }

  const buildEntry = topLevelEntries.find(
    (entry) => entry.isDirectory() && entry.name === 'build',
  );
  if (buildEntry) {
    return path.join(rootDir, 'build');
  }

  const topLevelDirectories = topLevelEntries.filter((entry) => entry.isDirectory());
  const topLevelFiles = topLevelEntries.filter((entry) => entry.isFile());

  if (topLevelDirectories.length === 1 && topLevelFiles.length === 0) {
    return path.join(rootDir, topLevelDirectories[0].name);
  }

  return rootDir;
}

function collectFilesRecursively(directoryPath, files = []) {
  for (const entry of fs.readdirSync(directoryPath, { withFileTypes: true })) {
    const entryPath = path.join(directoryPath, entry.name);
    if (entry.isDirectory()) {
      collectFilesRecursively(entryPath, files);
    } else {
      files.push(entryPath);
    }
  }

  return files;
}

function generatePackageHashFromDirectory(directoryPath, basePath) {
  if (!fs.lstatSync(directoryPath).isDirectory()) {
    throw new Error('Not a directory. Please either create a directory, or use hashFile().');
  }

  const files = collectFilesRecursively(directoryPath);
  if (files.length === 0) {
    throw new Error("Can't sign the release because no files were found.");
  }

  const entries = [];
  for (const filePath of files) {
    const relativePath = normalizePath(path.relative(basePath, filePath));
    if (!isIgnored(relativePath)) {
      entries.push(relativePath + ':' + hashFile(filePath));
    }
  }

  entries.sort();
  return crypto.createHash(HASH_ALGORITHM).update(JSON.stringify(entries)).digest('hex');
}

function base64urlEncode(value) {
  return Buffer.from(value).toString('base64url');
}

const normalizedPackageDir = path.join(normalizedRootDir, 'CodePush');
fs.rmSync(normalizedRootDir, { recursive: true, force: true });
fs.mkdirSync(normalizedPackageDir, { recursive: true });

copyDirectoryContents(resolvePackageSourceDir(tempDir), normalizedPackageDir);

const contentHash = generatePackageHashFromDirectory(normalizedPackageDir, normalizedRootDir);
const claims = {
  claimVersion: CURRENT_CLAIM_VERSION,
  contentHash,
};

const header = base64urlEncode(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
const payload = base64urlEncode(JSON.stringify(claims));
const signingInput = `${header}.${payload}`;
const privateKey = fs.readFileSync(privateKeyPath);
const signature = crypto
  .sign('RSA-SHA256', Buffer.from(signingInput, 'utf8'), privateKey)
  .toString('base64url');

fs.writeFileSync(
  path.join(normalizedPackageDir, METADATA_FILE_NAME),
  `${signingInput}.${signature}`,
  'utf8',
);

const generatedJwt = fs.readFileSync(path.join(normalizedPackageDir, METADATA_FILE_NAME), 'utf8');
const jwtContentHash = decodeJwtPayloadContentHash(generatedJwt);
const finalPackageHash = generatePackageHashFromDirectory(normalizedPackageDir, normalizedRootDir);

if (jwtContentHash !== finalPackageHash) {
  throw new Error(
    `Generated package hash mismatch: JWT contentHash=${jwtContentHash}, final package hash=${finalPackageHash}`,
  );
}

console.log(`Generated a release signature and wrote it to ${path.join('CodePush', METADATA_FILE_NAME)}`);
console.log(`Computed CodePush contentHash=${contentHash}`);
console.log(`Verified signed package hash=${finalPackageHash}`);
