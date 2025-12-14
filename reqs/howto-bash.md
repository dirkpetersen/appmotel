This guide is designed to instruct a coding agent (like Claude Code) to generate high-quality, modern, robust, and performant Bash scripts. It focuses on features available up to **Bash 4.4.20**, which is a widely deployed minimum standard (found in RHEL 8, older Ubuntu LTS.

---

# System Instructions: Modern Bash Coding Guidelines

**Target Version:** Bash 4.4.20
**Philosophy:** Robustness first, Readability second, Performance third.
**Format:** All generated Bash code must adhere to the following rules.

## 1. The Preamble (Strict Mode)
All scripts must begin with the "Bash Strict Mode" to catch errors early. Do not write scripts that fail silently.

```bash
#!/usr/bin/env bash
set -o errexit   # Exit on most errors (same as -e)
set -o nounset   # Disallow expansion of unset variables (same as -u)
set -o pipefail  # Return value of a pipeline is the status of the last command to exit with a non-zero status
IFS=$'\n\t'      # Set Internal Field Separator to newline and tab only (prevents space splitting issues)
```

## 2. Major Features to Leverage (Bash 4.0 - 4.4)
Do not write legacy `sh` compatible code. Utilize the specific features added in Bash 4.x that significantly improve logic and performance.

*   **Associative Arrays (Bash 4.0):** Use hashmaps for lookup tables instead of multiple arrays or `grep`.
    ```bash
    declare -A config_map
    config_map[user]="admin"
    config_map[port]="8080"
    ```
*   **Namerefs (Bash 4.3):** Use `declare -n` to pass variables by reference to functions. This allows functions to modify variables defined in the parent scope cleanly, avoiding global variable pollution.
*   **Parameter Transformation (Bash 4.4):** Use `${var@Q}` for safe quoting when generating commands dynamically.

## 3. "Strict Typing" and Variable Declarations
Bash is loosely typed, but we enforce structure using `declare`.
*   **Immutability:** Use `declare -r` for constants.
*   **Integers:** Use `declare -i` for math counters. This prevents string concatenation accidents during arithmetic.
*   **Scope:** **Never** use global variables inside functions unless absolutely necessary. Use `local` (or `declare` inside a function) for everything.

```bash
# Good
readonly MAX_RETRIES=5

update_count() {
  local -n counter_ref=$1 # Nameref: changes to counter_ref affect the variable passed in
  local -i increment=$2   # Integer type enforcement
  counter_ref=$((counter_ref + increment))
}
```

## 4. Conditionals: The Double Bracket
Abandon the single bracket `[ ... ]` (POSIX test). Always use the modern double bracket `[[ ... ]]` keyword.

**Why?**
1.  **Safety:** Variables inside `[[ ]]` do not need to be quoted (though quoting is still a good habit). Word splitting and glob expansion are suppressed.
2.  **Features:** Supports Regex matching (`=~`) and Pattern matching (`==`).
3.  **Logic:** Supports `&&` and `||` natively inside the brackets.

```bash
# Bad
if [ "$name" = "root" ] && [ -f "$file" ]; then ... fi

# Good (Modern)
if [[ "${name}" == "root" && -f "${file}" ]]; then
    # ...
fi

# Regex Matching (Native)
if [[ "${input}" =~ ^[0-9]+$ ]]; then
    echo "Input is an integer"
fi
```

## 5. Modern Command Line Parsing
Do not use `getopt` (the external binary). Do not use `getopts` if you need long options (e.g., `--help`).
Use a **manual `while` loop with `case`**. This is the most portable, dependency-free, and flexible method.

```bash
parse_params() {
  # Default values
  local param_verbose=0
  local param_file=""

  while :; do
    case "${1-}" in
    -h | --help) usage ;; # Function usage() must be defined
    -v | --verbose) param_verbose=1 ;;
    --no-color) NO_COLOR=1 ;;
    -f | --file) # Handle argument with value
      if [[ -z "${2-}" ]]; then die "Option $1 requires an argument"; fi
      param_file="${2}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done
  
  # Return logic or set globals if necessary for the specific script architecture
}
```

## 6. Maintainability and Functions
*   **Snake_case:** Use `snake_case` for function names and variable names. Uppercase is reserved for exported environment variables and constants.
*   **Modularization:** Break logic into small functions.
*   **Return Codes:** Use `return` for success/failure (0/1). Do not `echo` data out of a function unless that function is a "getter" specifically designed to be captured.

## 7. Performance Optimization
*   **Avoid Subshells:** Subshells are slow.
    *   *Bad:* `echo "$(date)"` (forks a process).
    *   *Good:* Use `printf` builtin features like `%(fmt)T` (available in Bash 4.2+).
*   **Avoid Pipes in Loops:**
    *   *Bad:* `cat file | while read line; do ... done` (Runs loop in subshell, variables are lost on exit).
    *   *Good:* `while IFS= read -r line; do ... done < file` (Runs in current shell).
*   **String Manipulation:** Use native Bash Parameter Expansion over `sed`/`awk` for simple operations.
    *   `${var#pattern}` (Remove from start)
    *   `${var%pattern}` (Remove from end)
    *   `${var/find/replace}`

---

# Golden Master Example
*Produce code following this template.*

```bash
#!/usr/bin/env bash

# -----------------------------------------------------------------------------
# Script Name: processor.sh
# Description: Demonstrates modern Bash 4.4 coding standards.
# -----------------------------------------------------------------------------

set -o errexit
set -o nounset
set -o pipefail
IFS=$'\n\t'

# Constants
readonly LOG_FILE="/tmp/processor.log"
readonly VERSION="1.0.0"

# -----------------------------------------------------------------------------
# Function: log_msg
# Description: Prints messages to stderr and log file with timestamp.
# Arguments:
#   $1 - Log level (INFO, ERROR)
#   $2 - Message
# -----------------------------------------------------------------------------
log_msg() {
  local level="$1"
  local msg="$2"
  # Bash 4.2+ native date formatting (fast, no subshell)
  printf "[%(%Y-%m-%d %H:%M:%S)T] [%s] %s\n" -1 "${level}" "${msg}" >&2
}

# -----------------------------------------------------------------------------
# Function: process_data
# Description: Uses nameref for clean variable manipulation (Bash 4.3+).
# -----------------------------------------------------------------------------
process_data() {
  local -n data_map=$1  # Passed by reference
  local -i multiplier=$2 # Enforce integer

  # Iterate over associative array keys
  for key in "${!data_map[@]}"; do
    if [[ "${data_map[$key]}" =~ ^[0-9]+$ ]]; then
      data_map[$key]=$((data_map[$key] * multiplier))
    fi
  done
}

# -----------------------------------------------------------------------------
# Function: main
# -----------------------------------------------------------------------------
main() {
  local verbose=0
  local input_file=""
  
  # Argument Parsing
  while :; do
    case "${1-}" in
      -h|--help)
        echo "Usage: $0 [--verbose] --file <path>"
        exit 0
        ;;
      -v|--verbose)
        verbose=1
        ;;
      -f|--file)
        if [[ -n "${2-}" ]]; then
          input_file="$2"
          shift
        else
          log_msg "ERROR" "--file requires a non-empty argument."
          exit 1
        fi
        ;;
      -?*)
        log_msg "ERROR" "Unknown option: $1"
        exit 1
        ;;
      *)
        break
        ;;
    esac
    shift
  done

  # Validation using Double Brackets
  if [[ -z "${input_file}" ]]; then
    log_msg "ERROR" "Input file is required."
    exit 1
  fi

  # Using Associative Array (Bash 4.0+)
  declare -A stats
  stats[cpu]=50
  stats[mem]=1024

  log_msg "INFO" "Starting processing..."
  
  # Pass associative array by reference
  process_data stats 2

  if [[ "${verbose}" -eq 1 ]]; then
    # Safe quoting with @Q (Bash 4.4)
    log_msg "INFO" "Processed CPU Stats: ${stats[cpu]@Q}"
  fi
}

main "$@"
```
