#!/bin/bash
#
# Common utility functions for signing CodePush zip packages.

#######################################
# Signs a CodePush zip package in-place by adding a .codepushrelease JWT file.
# Globals:
#   PACKAGE_PATH
#   CODE_PUSH_PRIVATE_KEY_PATH
# Arguments:
#   None
#######################################
sign_code_push_package() {
  if [ -z "${CODE_PUSH_PRIVATE_KEY_PATH}" ]; then
    return 0
  fi

  if [ ! -f "$CODE_PUSH_PRIVATE_KEY_PATH" ]; then
    echo "CodePush private key not found at: $CODE_PUSH_PRIVATE_KEY_PATH"
    exit 1
  fi

  case "$PACKAGE_PATH" in
    *.zip) ;;
    *)
      echo "CodePush signing currently supports zip packages only. PACKAGE_PATH must point to a .zip file."
      exit 1
      ;;
  esac

  local package_dir
  package_dir="$(cd "$(dirname "$PACKAGE_PATH")" && pwd)"
  local package_name
  package_name="$(basename "$PACKAGE_PATH")"
  local temp_dir
  temp_dir="$(mktemp -d)"
  local temp_package_path="$package_dir/signed-$package_name"

  unzip -q "$PACKAGE_PATH" -d "$temp_dir"

  TEMP_DIR="$temp_dir" CODE_PUSH_PRIVATE_KEY_PATH="$CODE_PUSH_PRIVATE_KEY_PATH" node <<'EOF'
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const tempDir = process.env.TEMP_DIR;
const privateKeyPath = process.env.CODE_PUSH_PRIVATE_KEY_PATH;

function isHashIgnored(relativePath) {
  return (
    relativePath.startsWith('__MACOSX/') ||
    relativePath === '.DS_Store' ||
    relativePath.endsWith('/.DS_Store') ||
    relativePath === '.codepushrelease' ||
    relativePath.endsWith('/.codepushrelease')
  );
}

function computeHash(filePath) {
  const hash = crypto.createHash('sha256');
  hash.update(fs.readFileSync(filePath));
  return hash.digest('hex');
}

function addContentsOfFolderToManifest(folderPath, pathPrefix, manifest) {
  const folderFiles = fs.readdirSync(folderPath);

  for (const fileName of folderFiles) {
    const fullFilePath = path.join(folderPath, fileName);
    const relativePath = pathPrefix ? `${pathPrefix}/${fileName}` : fileName;

    if (isHashIgnored(relativePath)) {
      continue;
    }

    const stat = fs.statSync(fullFilePath);
    if (stat.isDirectory()) {
      addContentsOfFolderToManifest(fullFilePath, relativePath, manifest);
    } else {
      manifest.push(`${relativePath}:${computeHash(fullFilePath)}`);
    }
  }
}

const manifest = [];
addContentsOfFolderToManifest(tempDir, '', manifest);
manifest.sort();

const manifestString = JSON.stringify(manifest).replace(/\\\//g, '/');
const contentHash = crypto.createHash('sha256').update(Buffer.from(manifestString, 'utf8')).digest('hex');

const header = Buffer.from(JSON.stringify({ alg: 'RS256', typ: 'JWT' })).toString('base64url');
const payload = Buffer.from(JSON.stringify({ contentHash })).toString('base64url');
const signingInput = `${header}.${payload}`;
const privateKey = fs.readFileSync(privateKeyPath, 'utf8');
const signature = crypto.sign('RSA-SHA256', Buffer.from(signingInput, 'utf8'), privateKey).toString('base64url');

const codePushDir = path.join(tempDir, 'CodePush');
fs.mkdirSync(codePushDir, { recursive: true });
fs.writeFileSync(path.join(codePushDir, '.codepushrelease'), `${signingInput}.${signature}`, 'utf8');

console.log(`Signed CodePush package with contentHash=${contentHash}`);
EOF

  (
    cd "$temp_dir"
    rm -f "$temp_package_path"
    zip -qr "$temp_package_path" .
  )

  mv "$temp_package_path" "$PACKAGE_PATH"
  rm -rf "$temp_dir"
}
