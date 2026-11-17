#!/usr/bin/env bash
# Strict service_state.env parser function
# Arguments: <state_file_path>
# Outputs: prints WAS_ENABLED and WAS_ACTIVE on success as two lines
parse_service_state_strict() {
  local state_file="$1"
  local has_enabled=false
  local has_active=false
  local was_enabled=""
  local was_active=""
  local line_count=0

  if [[ ! -f "$state_file" ]]; then
    echo "ERROR: state file missing" >&2
    return 1
  fi

  while IFS='=' read -r key val || [[ -n "$key" ]]; do
    key=$(echo "$key" | tr -d ' \t\r\n')
    val=$(echo "$val" | tr -d ' \t\r\n')

    [[ -z "$key" ]] && continue
    line_count=$((line_count + 1))

    case "$key" in
      WAS_ENABLED)
        if [[ "$has_enabled" == "true" ]]; then
          echo "ERROR: duplicate key WAS_ENABLED" >&2
          return 1
        fi
        if [[ "$val" != "yes" && "$val" != "no" ]]; then
          echo "ERROR: invalid value for WAS_ENABLED: $val" >&2
          return 1
        fi
        was_enabled="$val"
        has_enabled=true
        ;;
      WAS_ACTIVE)
        if [[ "$has_active" == "true" ]]; then
          echo "ERROR: duplicate key WAS_ACTIVE" >&2
          return 1
        fi
        if [[ "$val" != "yes" && "$val" != "no" ]]; then
          echo "ERROR: invalid value for WAS_ACTIVE: $val" >&2
          return 1
        fi
        was_active="$val"
        has_active=true
        ;;
      *)
        echo "ERROR: unknown or malicious key: $key" >&2
        return 1
        ;;
    esac
  done < "$state_file"

  if [[ "$has_enabled" != "true" || "$has_active" != "true" ]]; then
    echo "ERROR: missing required keys" >&2
    return 1
  fi

  echo "WAS_ENABLED=$was_enabled"
  echo "WAS_ACTIVE=$was_active"
  return 0
}
