#!/bin/bash
#
# Common utility functions for signing CodePush zip packages.
#
# The package hashing/signing behavior is adapted from the upstream CodePush CLI:
# shm-open/code-push-cli@4a5916d0144e9dd2cb4beacda186d76e888ff79e
# - src/release-hooks/signing.ts
# - src/lib/hash-utils.ts
# - src/release-hooks/core-release.ts

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
  local normalized_root_dir="$temp_dir/__signed_release__"
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  unzip -q "$PACKAGE_PATH" -d "$temp_dir"

  TEMP_DIR="$temp_dir" \
  CODE_PUSH_PRIVATE_KEY_PATH="$CODE_PUSH_PRIVATE_KEY_PATH" \
  CODE_PUSH_NORMALIZED_ROOT_DIR="$normalized_root_dir" \
  node "$script_dir/codepush_sign_package.js"

  (
    cd "$normalized_root_dir"
    rm -f "$temp_package_path"
    zip -qr "$temp_package_path" .
  )

  mv "$temp_package_path" "$PACKAGE_PATH"
  rm -rf "$temp_dir"
}
