#!/bin/bash
#
# Common utility functions for signing CodePush zip packages.

#######################################
# Encodes stdin as base64url without padding.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes base64url-encoded content to stdout.
#######################################
base64url_encode() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

#######################################
# Computes the SHA-256 hash of a file.
# Globals:
#   None
# Arguments:
#   File path.
# Outputs:
#   Writes the lowercase SHA-256 hex digest to stdout.
#######################################
sha256_file() {
  openssl dgst -sha256 "$1" | awk '{print $NF}'
}

#######################################
# Computes the SHA-256 hash of stdin.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes the lowercase SHA-256 hex digest to stdout.
#######################################
sha256_stdin() {
  openssl dgst -sha256 | awk '{print $NF}'
}

#######################################
# Returns zero when the relative path should be ignored for CodePush hashing.
# Globals:
#   None
# Arguments:
#   Relative path.
#######################################
is_codepush_hash_ignored() {
  local relative_path="$1"

  [[ "$relative_path" == __MACOSX/* ]] ||
  [[ "$relative_path" == ".DS_Store" ]] ||
  [[ "$relative_path" == */.DS_Store ]] ||
  [[ "$relative_path" == ".codepushrelease" ]] ||
  [[ "$relative_path" == */.codepushrelease ]]
}

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

  local manifest_entries
  manifest_entries="$(
    cd "$temp_dir"

    while IFS= read -r file_path; do
      local relative_path
      relative_path="${file_path#./}"

      if is_codepush_hash_ignored "$relative_path"; then
        continue
      fi

      printf '%s:%s\n' "$relative_path" "$(sha256_file "$file_path")"
    done < <(find . -type f | LC_ALL=C sort)
  )"

  local manifest_json
  manifest_json="$(printf '%s\n' "$manifest_entries" | jq -R . | jq -s -c '.' | sed 's#\\/#/#g')"
  local content_hash
  content_hash="$(printf '%s' "$manifest_json" | sha256_stdin)"

  local jwt_header
  jwt_header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | base64url_encode)"
  local jwt_payload
  jwt_payload="$(printf '%s' "{\"contentHash\":\"$content_hash\"}" | base64url_encode)"
  local jwt_signing_input
  jwt_signing_input="${jwt_header}.${jwt_payload}"
  local jwt_signature
  jwt_signature="$(
    printf '%s' "$jwt_signing_input" \
      | openssl dgst -sha256 -sign "$CODE_PUSH_PRIVATE_KEY_PATH" \
      | base64url_encode
  )"

  printf '%s.%s' "$jwt_signing_input" "$jwt_signature" > "$temp_dir/.codepushrelease"

  (
    cd "$temp_dir"
    rm -f "$temp_package_path"
    zip -qr "$temp_package_path" .
  )

  mv "$temp_package_path" "$PACKAGE_PATH"
  rm -rf "$temp_dir"
}
