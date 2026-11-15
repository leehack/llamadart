set -euo pipefail
config=
dir="$PROJECT_DIR"
while [ "$dir" != / ]; do
  if [ -f "$dir/.dart_tool/package_config.json" ]; then
    config="$dir/.dart_tool/package_config.json"
    break
  fi
  dir="$(dirname "$dir")"
done
if [ -z "$config" ]; then
  echo "error: no .dart_tool/package_config.json above $PROJECT_DIR; run flutter pub get" >&2
  exit 1
fi
root=
count="$(plutil -extract packages raw -o - "$config")"
for ((i = 0; i < count; i++)); do
  if [ "$(plutil -extract "packages.$i.name" raw -o - "$config")" = llamadart ]; then
    root="$(plutil -extract "packages.$i.rootUri" raw -o - "$config")"
    break
  fi
done
if [ -z "$root" ]; then
  echo "error: llamadart is not resolved in $config" >&2
  exit 1
fi
case "$root" in
  file://*) root="${root#file://}" ;;
  *) root="$(dirname "$config")/$root" ;;
esac
root="$(printf '%b' "${root//%/\\x}")"
bash "$root/tool/macos_litert_lm_prepare_app.sh" "$TARGET_BUILD_DIR/$WRAPPER_NAME"
