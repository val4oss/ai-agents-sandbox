# Contributing Guidelines

## Coding Style

* All script should be POSIX compliant and follow `shellcheck` recommendations.
* Script lines should not exceed 80 characters in length.
* Use consistent indentation (4 spaces) and avoid tabs.

## Commit Message Guidelines

Follow the [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
specification for commit messages. This helps maintain a clear and consistent
commit history.

```
<type>[optional scope]: <description>

[optional body]
```

### Allowed Types

* **feat**: A new feature
* **fix**: A bug fix
* **docs**: Documentation only changes
* **style**: Changes that do not affect the meaning of the code (white-space, formatting, etc.)
* **refactor**: A code change that neither fixes a bug nor adds a feature
* **perf**: A code change that improves performance
* **test**: Adding missing tests or correcting existing tests
* **build**: Changes that affect the build system or external dependencies
* **ci**: Changes to our CI configuration files and scripts
* **chore**: Other changes that don't modify src or test files
* **revert**: Reverts a previous commit

### Examples

```
feat: add new agent

Add this new agent to the list of available agents.
```
