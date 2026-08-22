#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

native_repo="${LLAMADART_NATIVE_REPO:-leehack/llamadart-native}"
tag_input="${LLAMADART_NATIVE_TAG:-latest}"
header_root="${LLAMADART_FFIGEN_HEADER_ROOT:-.dart_tool/llamadart/ffigen_headers}"
run_ffigen=1

usage() {
  cat <<'EOF'
Usage: tool/native/sync_native_headers_and_bindings.sh [options]

Downloads llamadart-native release header bundle for a tag and regenerates
bindings using ffigen.

Options:
  --tag <tag|latest>      Stable/nightly tag or wrapper rebuild (default: latest)
  --repo <owner/name>     Native repository slug (default: leehack/llamadart-native)
  --header-root <path>    Header staging path (default: .dart_tool/llamadart/ffigen_headers)
  --skip-ffigen           Only sync headers, do not run ffigen
  --help                  Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      tag_input="$2"
      shift 2
      ;;
    --repo)
      native_repo="$2"
      shift 2
      ;;
    --header-root)
      header_root="$2"
      shift 2
      ;;
    --skip-ffigen)
      run_ffigen=0
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

stable_tag_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
stable_wrapper_tag_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-[1-9][0-9]*$'
nightly_tag_pattern='^b[0-9]+$'
nightly_wrapper_tag_pattern='^b[0-9]+-[1-9][0-9]*$'
legacy_wrapper_tag_pattern='^b[0-9]+-llamadart\.[1-9][0-9]*$'

is_supported_native_tag() {
  [[ "$1" =~ ${stable_tag_pattern} ]] ||
    [[ "$1" =~ ${stable_wrapper_tag_pattern} ]] ||
    [[ "$1" =~ ${nightly_tag_pattern} ]] ||
    [[ "$1" =~ ${nightly_wrapper_tag_pattern} ]] ||
    [[ "$1" =~ ${legacy_wrapper_tag_pattern} ]]
}

is_stable_channel_tag() {
  [[ "$1" =~ ${stable_tag_pattern} || "$1" =~ ${stable_wrapper_tag_pattern} ]]
}

if [[ "${tag_input}" != "latest" && -n "${tag_input}" ]] &&
  ! is_supported_native_tag "${tag_input}"; then
  echo "Invalid llamadart-native tag: ${tag_input}" >&2
  echo "Expected stable vMAJOR.MINOR.PATCH, stable wrapper" \
    "vMAJOR.MINOR.PATCH-N, historical/nightly bNNNN, nightly wrapper" \
    "bNNNN-N, or legacy wrapper artifact bNNNN-llamadart.N." >&2
  exit 1
fi

curl_headers=(
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28"
)
if [[ -n "${GH_TOKEN:-}" ]]; then
  curl_headers+=(-H "Authorization: Bearer ${GH_TOKEN}")
fi

if [[ "${tag_input}" == "latest" || -z "${tag_input}" ]]; then
  release_api_url="https://api.github.com/repos/${native_repo}/releases/latest"
else
  release_api_url="https://api.github.com/repos/${native_repo}/releases/tags/${tag_input}"
fi

release_json="$(
  curl -fsSL "${curl_headers[@]}" "${release_api_url}"
)"

resolved_tag="$(
  python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'])" <<<"${release_json}"
)"

if ! is_supported_native_tag "${resolved_tag}"; then
  echo "Release metadata resolved unsupported tag: ${resolved_tag}" >&2
  exit 1
fi
if [[ "${tag_input}" == "latest" ]] && ! is_stable_channel_tag "${resolved_tag}"; then
  echo "llamadart-native latest resolved nightly tag ${resolved_tag};" \
    "select historical tags explicitly." >&2
  exit 1
fi
if [[ "${tag_input}" != "latest" && -n "${tag_input}" ]] &&
  [[ "${resolved_tag}" != "${tag_input}" ]]; then
  echo "Requested ${tag_input}, but release metadata resolved" \
    "${resolved_tag}; refusing version skew." >&2
  exit 1
fi

asset_name="llamadart-native-headers-${resolved_tag}.tar.gz"
asset_url="$(
  python3 -c "import json,sys; name=sys.argv[1]; data=json.load(sys.stdin); print(next((a.get('browser_download_url','') for a in data.get('assets',[]) if a.get('name')==name),''))" \
    "${asset_name}" <<<"${release_json}"
)"

if [[ -z "${asset_url}" ]]; then
  echo "Could not find release asset: ${asset_name}" >&2
  exit 1
fi

asset_digest="$(
  python3 -c "import json,sys; name=sys.argv[1]; data=json.load(sys.stdin); print(next((a.get('digest','') for a in data.get('assets',[]) if a.get('name')==name),''))" \
    "${asset_name}" <<<"${release_json}"
)"

tmp_dir="${TMPDIR:-/tmp}/llamadart-native-headers-${resolved_tag}-$$"
archive_path="${tmp_dir}/${asset_name}"
extract_dir="${tmp_dir}/extract"
trap 'rm -rf "${tmp_dir}"' EXIT

mkdir -p "${extract_dir}"
echo "Downloading ${asset_name} from ${native_repo} (${resolved_tag})..."
curl -fsSL "${curl_headers[@]}" "${asset_url}" -o "${archive_path}"
if [[ "${asset_digest}" == sha256:* ]]; then
  expected_sha256="${asset_digest#sha256:}"
  if command -v shasum >/dev/null 2>&1; then
    actual_sha256="$(shasum -a 256 "${archive_path}" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    actual_sha256="$(sha256sum "${archive_path}" | awk '{print $1}')"
  else
    echo "No SHA-256 tool available to verify ${asset_name}" >&2
    exit 1
  fi
  if [[ "${actual_sha256}" != "${expected_sha256}" ]]; then
    echo "Header archive checksum mismatch for ${asset_name}: expected" \
      "${expected_sha256}, got ${actual_sha256}." >&2
    exit 1
  fi
elif is_stable_channel_tag "${resolved_tag}"; then
  echo "Stable release ${resolved_tag} does not publish a SHA-256 digest for ${asset_name}." >&2
  exit 1
else
  echo "Warning: historical release ${resolved_tag} has no GitHub SHA-256" \
    "digest for ${asset_name}." >&2
fi
tar -xzf "${archive_path}" -C "${extract_dir}"

llama_include_src=""
ggml_include_src=""
mtmd_src=""
wrapper_header_src=""

if [[ -d "${extract_dir}/llama_cpp/include" ]]; then
  llama_include_src="${extract_dir}/llama_cpp/include"
  ggml_include_src="${extract_dir}/llama_cpp/ggml/include"
  mtmd_src="${extract_dir}/llama_cpp/tools/mtmd"
  wrapper_header_src="${extract_dir}/libllamadart/llama_dart_wrapper.h"
elif [[ -d "${extract_dir}/include/llama.cpp" ]]; then
  # Backward compatibility for earlier archive layout.
  llama_include_src="${extract_dir}/include/llama.cpp"
  ggml_include_src="${extract_dir}/include/ggml"
  mtmd_src="${extract_dir}/include/llama.cpp"
  wrapper_header_src="${extract_dir}/include/llama_dart_wrapper.h"
else
  echo "Unsupported header archive layout in ${asset_name}" >&2
  exit 1
fi

rm -rf "${header_root}"
mkdir -p "${header_root}/llama_cpp/include"
mkdir -p "${header_root}/llama_cpp/ggml/include"
mkdir -p "${header_root}/llama_cpp/tools/mtmd"
mkdir -p "${header_root}/libllamadart"

rsync -a --delete "${llama_include_src}/" "${header_root}/llama_cpp/include/"
rsync -a --delete "${ggml_include_src}/" "${header_root}/llama_cpp/ggml/include/"
cp "${mtmd_src}/mtmd.h" "${header_root}/llama_cpp/tools/mtmd/mtmd.h"
cp "${mtmd_src}/mtmd-helper.h" "${header_root}/llama_cpp/tools/mtmd/mtmd-helper.h"
cp "${wrapper_header_src}" "${header_root}/libllamadart/llama_dart_wrapper.h"

echo "Synced headers to ${header_root}"

if [[ "${run_ffigen}" == "1" ]]; then
  echo "Running ffigen..."
  dart run ffigen --config ffigen.yaml
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "resolved_tag=${resolved_tag}" >> "${GITHUB_OUTPUT}"
fi

echo "Resolved tag: ${resolved_tag}"
