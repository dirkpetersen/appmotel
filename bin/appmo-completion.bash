#!/usr/bin/env bash
# Bash completion script for appmo CLI
# Install: source /path/to/appmo-completion.bash
# Or copy to: /etc/bash_completion.d/appmo

_appmo_completions() {
  local cur prev opts
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  # Main commands
  local commands="add remove list status start stop restart update autopull logs exec backup restore backups help"

  # Get list of apps for completion
  local apps=""
  if [[ -d "/home/appmotel/.config/appmotel/apps" ]]; then
    apps=$(ls /home/appmotel/.config/appmotel/apps 2>/dev/null | tr '\n' ' ')
  fi

  case "${COMP_CWORD}" in
    1)
      # First argument: complete commands
      COMPREPLY=($(compgen -W "${commands}" -- "${cur}"))
      ;;
    2)
      # Second argument: depends on command
      case "${prev}" in
        add)
          # No completion for add (needs app-name, github-url, branch)
          ;;
        remove|status|start|stop|restart|update|logs|exec|backup|restore|backups)
          # Complete with app names
          COMPREPLY=($(compgen -W "${apps}" -- "${cur}"))
          ;;
        list|help)
          # No further arguments
          ;;
      esac
      ;;
    3)
      # Third argument: depends on command
      local cmd="${COMP_WORDS[1]}"
      case "${cmd}" in
        restore)
          # Complete with backup IDs
          local app_name="${COMP_WORDS[2]}"
          local backups=""
          if [[ -d "/home/appmotel/.local/share/appmotel-backups/${app_name}" ]]; then
            backups=$(ls /home/appmotel/.local/share/appmotel-backups/${app_name} 2>/dev/null | tr '\n' ' ')
          fi
          COMPREPLY=($(compgen -W "${backups}" -- "${cur}"))
          ;;
      esac
      ;;
  esac

  return 0
}

complete -F _appmo_completions appmo
