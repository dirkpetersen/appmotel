---
name: bash
description: Bash 4.4.20 coding standards with strict mode, modern features, and best practices
---

# Bash Coding Guidelines (Bash 4.4.20)

**Target Version:** Bash 4.4.20
**Philosophy:** Robustness first, Readability second, Performance third.

## 1. The Preamble (Strict Mode)

All scripts must begin with the "Bash Strict Mode" to catch errors early:

```bash
#!/usr/bin/env bash
set -o errexit   # Exit on most errors (same as -e)
set -o nounset   # Disallow expansion of unset variables (same as -u)
set -o pipefail  # Return value of a pipeline is the status of the last command to exit with a non-zero status
IFS=$'\n\t'      # Set Internal Field Separator to newline and tab only
```

## 2. Modern Bash Features (4.0 - 4.4)

*   **Associative Arrays (Bash 4.0):** Use hashmaps for lookup tables
    ```bash
    declare -A config_map
    config_map[user]="admin"
    config_map[port]="8080"
    ```
*   **Namerefs (Bash 4.3):** Use `declare -n` to pass variables by reference
*   **Parameter Transformation (Bash 4.4):** Use `${var@Q}` for safe quoting

## 3. Variable Declarations

*   **Immutability:** Use `declare -r` or `readonly` for constants
*   **Integers:** Use `declare -i` for math counters
*   **Scope:** Always use `local` for function variables

```bash
readonly MAX_RETRIES=5

update_count() {
  local -n counter_ref=$1 # Nameref
  local -i increment=$2   # Integer type
  counter_ref=$((counter_ref + increment))
}
```

## 4. Conditionals: Double Bracket

Always use `[[ ... ]]` instead of `[ ... ]`:

1.  **Safety:** No word splitting or glob expansion
2.  **Features:** Supports Regex (`=~`) and Pattern matching (`==`)
3.  **Logic:** Supports `&&` and `||` natively

```bash
# Regex Matching
if [[ "${input}" =~ ^[0-9]+$ ]]; then
    echo "Input is an integer"
fi
```

## 5. Command Line Parsing

Use a manual `while` loop with `case` (not `getopt` or `getopts`):

```bash
while :; do
  case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) param_verbose=1 ;;
    -f | --file)
      if [[ -z "${2-}" ]]; then die "Option $1 requires an argument"; fi
      param_file="${2}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
  esac
  shift
done
```

## 6. Naming and Style

*   **Snake_case:** Use `snake_case` for function and variable names
*   **Uppercase:** Reserved for exported environment variables and constants
*   **Modularization:** Break logic into small functions
*   **Return Codes:** Use `return` for success/failure (0/1)

## 7. Performance Optimization

*   **Avoid Subshells:** Use `printf "[%(%Y-%m-%d %H:%M:%S)T]" -1` for timestamps (Bash 4.2+)
*   **Avoid Pipes in Loops:** Use `while IFS= read -r line; do ... done < file`
*   **String Manipulation:** Use native Parameter Expansion:
    *   `${var#pattern}` (Remove from start)
    *   `${var%pattern}` (Remove from end)
    *   `${var/find/replace}`

## Golden Master Template

```bash
#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

readonly LOG_FILE="/tmp/processor.log"
readonly VERSION="1.0.0"

log_msg() {
  local level="$1"
  local msg="$2"
  printf "[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n" -1 "${level}" "${msg}" >&2
}

main() {
  local verbose=0
  local input_file=""

  while :; do
    case "${1-}" in
      -h|--help)
        echo "Usage: $0 [--verbose] --file <path>"
        exit 0
        ;;
      -v|--verbose) verbose=1 ;;
      -f|--file)
        if [[ -n "${2-}" ]]; then
          input_file="$2"
          shift
        else
          log_msg "ERROR" "--file requires an argument."
          exit 1
        fi
        ;;
      -?*) log_msg "ERROR" "Unknown option: $1"; exit 1 ;;
      *) break ;;
    esac
    shift
  done

  if [[ -z "${input_file}" ]]; then
    log_msg "ERROR" "Input file is required."
    exit 1
  fi

  declare -A stats
  stats[cpu]=50
  stats[mem]=1024

  log_msg "INFO" "Starting processing..."
}

main "$@"
```
