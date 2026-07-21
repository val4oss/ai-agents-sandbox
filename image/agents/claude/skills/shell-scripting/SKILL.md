---
name: shell-scripting
description: Expert in Shell scripting with deep knowledge of shell programming and Linux system
allowed-tools: Read, Grep, Write, Bash(shellcheck *), Bash(grep *), Bash(find *), Bash(cat *), Bash(awk *), Bash(sed *), Bash(sort *), Bash(cut *), Bash(head *), Bash(tail *), Bash(tr *), Bash(printf *), Bash(test *), Bash(readlink *), Bash(realpath *), Bash(dirname *), Bash(basename *), Bash(mkdir *), Bash(cp *), Bash(ls *)
---

## Core Principles

* Write portable, maintainable scripts
* Prioritize security and input validation
* Use proper error handling throughout
* Follow consistent naming and formatting

## Naming & Formating

* Maximum line length of 80 characters
* Use 4 spaces for indentation, no tabs
* Use descriptive names for scripts, functions and variables
  (e.g. `backup_objects.sh`, `create_backup()`, `backup_dir`)
* Employ modular scripts with functions to enhance readability and facilitate
  reuse
* Include comments for each major section or function
  * One comment line per function, describing its purpose and usage

    ```shell
    # This is a shorst description of the function's purpose and usage 
    function() {
      ...
    }
    ```

  * Section header comments
 
    ```shell
    # ========
    # Includes
    # --------
    ```

* Use global variables in uppercase with underscores for constants
  (e.g. `PRJ_ID`)
* Use lowercase with underscores for functions and variable names
  (e.g. `this_function()`, `this_variable`)
* Use underscores prefix for private/internal functions and variables
  (e.g. `_this_function()`, `_this_variable`)
* Always use `_ret` variable to store return values from functions, and return
  it at the end of the function. One return per function. And store the return
  values into a global variable

    ```shell
    # Return codes
    SUCCESS=0
    FAILURE=1
    ```

## Structure

* Use a consistent structure for scripts:
  * Shebang line (e.g. `#!/bin/sh`)
  * Script description and usage instructions
  * License information AGPLv3
  * Global variable declarations
  * Include external scripts or libraries
  * Internal Functions definitions that are only used within the script
  * Main Functions definitions that can be shared across scripts
  * Actions functions that perform the main tasks of the script
    (e.g. `usage()`, `build()`)
  * Main script logic, entrypoint with some verifiacations, arguments
    parsing and calling the main functions

## Input Validation

* Input Validation & Security
* Validate all inputs using getopts or manual validation logic
* Avoid hardcoding; use environment variables or parameterized inputs
* Apply the principle of least privilege in access and permissions
* Quote all variable expansions to prevent word splitting
* Sanitize user input before use


## Code Quality

* Ensure portability by using POSIX-compliant syntax
* Use shellcheck to lint scripts and improve quality
* Redirect output to log files where appropriate, separating stdout and stderr
* Use meaningful exit codes
* Use functions to encapsulate logic and avoid code duplication
* Always integrate an helper and usage argument to provide guidance on script
  usage
* Always create and use the `printer.sh` to use `print_xxx()` functions with
  verbose and quiet modes, and to print messages to stdout or stderr with colors
  and formatting.


## Aditional resources

- printer script to include: [printer.sh](resources/printer.sh)
- For script shell examples, see [sample.md](examples/sample.md)
