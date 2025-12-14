# Application Requirements

In this folder we document the application requirements as instructions for coding agents such as Claude Code.

## Documentation Files

- **howto-bash.md** - Bash coding standards and guidelines (Bash 4.4.20)
- **traefik-config.md** - Complete Traefik installation and configuration guide
- **TROUBLESHOOTING.md** - Common issues and debugging procedures

## Writing code

Please use Bash <= 4.4.20 for all installation and configuration tasks and also for most general coding tasks. Important: follow the guidelines in file howto-bash.md.
You may use sed for editing config files as well but always make sure that your actions are strictly idempotent. You can implement advanced features in Go but only if it makes absolutely no sense to write them in Bash, for example if the code would be unmaintainable.

## Installation

The Appmotel PaaS system should install 


