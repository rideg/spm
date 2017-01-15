#!/usr/bin/env bash

__spm_import_fatal() {
  (>&2 echo "SPM ERROR: $1")
  exit 1
}

require() {
  if [[ ! -p "/tmp/spm/pipe_$$" ]]; then
    [[ -d "/tmp/spm" ]] || mkdir -p "/tmp/spm"
    mkfifo "/tmp/spm/pipe_$$"
    exec 9<> "/tmp/spm/pipe_$$"
    trap 'rm -f /tmp/spm/pipe_$$' EXIT
    declare -gA __SPM_PACKAGES=()
    declare -ga __SPM_PATHS=()
    declare -ga __SPM_IMPORT_STACK=()
    declare -gA __SPM_SEEDS=()
    shopt -qs expand_aliases
  fi
}

import() {
  [[ ! -p "/tmp/spm/pipe_$$" ]] && __spm_import_fatal 'No SPM path defined. Call "require" first.'
  local file
  local is_debug=1
  local mnemonic
  declare -a split
  [[ $# -eq 0 ]] && __spm_import_fatal "Please provide a package to import"

  if [[ $# -eq 3 ]]; then
    if [[ "$2" == "as" ]]; then
      mnemonic="$3"
    else
      __spm_import_fatal "Unknown argument: $2"
    fi
  elif [[ $# -eq 2 || $# -gt 3 ]]; then
    __spm_import_fatal "Incorrect number of arguments"
  else
    IFS='/' read -r -a split <<< "$1"
    mnemonic="${split[-1]}"
  fi 

  local package_name="${1//\//_}"
  # Check if package exists.
  if [[ -z ${__SPM_PACKAGES[$package_name]} ]]; then 

    # Check for circular dependency.
    for elem in "${__SPM_IMPORT_STACK[@]}"; do
      [[ "$elem" == "$package_name" ]] && \
        __spm_import_fatal "Circular dependency has been detected"
    done 

    # Check for corresponding file.
    for dir in "${__SPM_PATHS[@]}"; do
      file="$dir/${1}.sh"
      [[ -f "$file" && -r "$file" ]] && break 
      unset file
    done
    [[ -z "$file" ]] && __spm_import_fatal "Cannot find package: $package_name"

    # Create a unique seed.
    local seed="_${RANDOM}${RANDOM}"
    while [[ -n ${__SPM_SEEDS[$seed]:+exists} ]]; do
      seed="_${RANDOM}${RANDOM}"
    done 
    __SPM_SEEDS[$seed]='0'

    # Create package descriptor.
    local package="_${seed}_package"
    local package_functions="_${seed}_functions"
    local package_imports="_${seed}_imports"

    __SPM_PACKAGES[$package_name]="$package"

    eval "declare -gA $package"
    eval "declare -gA $package_functions"
    eval "declare -gA $package_imports"

    eval "$package[functions]=$package_functions"
    eval "$package[imports]=$package_imports"

    # Add this by default
    eval "$package_imports[this]=$package"

    # Recurse
    __SPM_IMPORT_STACK=("$package_name" "${__SPM_IMPORT_STACK[@]}")
    # shellcheck source=/dev/null
    . "$file" || __spm_import_fatal "Failure while importing package: $package"
    __SPM_IMPORT_STACK=("${__SPM_IMPORT_STACK[@]:1}")

    # Read all functions.
    declare -a all_functs=()
    declare -F >&9
    echo "end" >&9
    # shellcheck disable=SC2034
    while read -r -u 9 dec par name; do
      [[ "$dec" == 'end' ]] && break
      all_functs=("${all_functs[@]}" "$name")
    done
    # Get functions for a given package
    shopt -q extdebug || is_debug=0
    [[ $is_debug -eq 1 ]] || shopt -qs extdebug 
    declare -a functs=()
    for funct in "${all_functs[@]}"; do
      declare -F "$funct" >&9
      # shellcheck disable=SC2034
      local name line funct_file
      read -u 9 -r name line funct_file
      if [[ "$funct_file" == "$file" ]]; then
        functs=("${functs[@]}" "$name")
      fi
    done
    [[ $is_debug -eq 1 ]] || shopt -qu extdebug
    unset all_functs

    # Generate unique function names to avoid collision.
    local index=1 
    for funct in "${functs[@]}"; do
      eval "$package_functions[$funct]=_${seed}_f${index}_${funct}"
      ((index++))
    done
    # Get import short names
    declare -a short_names
    eval "short_names=\${!${package_imports}[@]}"
    # Re-declare functions.
    declare -a split
    for funct in "${functs[@]}"; do
      type "$funct" >&9
      echo '<<<END>>>' >&9
      local line
      local new_source
      local new_name
      eval "new_name=\"\${$package_functions[$funct]}\""
      new_source="$new_name () { "
      # skip the first three lines
      IFS=$'\n' read -u 9 -r line
      IFS=$'\n' read -u 9 -r line
      IFS=$'\n' read -u 9 -r line
      while read -u 9 -r line; do
        [[ "$line" == '<<<END>>>' ]] && break
        for short_name in ${short_names[@]}; do
          while [[ "$line" =~ $short_name::([_a-zA-Z][_a-zA-Z0-9]*)[:blank:]* ]]; do
            local __
            eval "__=\${$package_imports[$short_name]}"
            eval "__=\${$__[functions]}"
            eval "__=\${$__[${BASH_REMATCH[1]}]}"
            line=${line/${short_name}::${BASH_REMATCH[1]}/$__}
          done 
        done
        new_source="$new_source $line"
      done
      eval "${new_source: : -1};}"
      #echo -e "${new_source: : -1};}"
      if [[ ${#__SPM_IMPORT_STACK[@]} -eq 0 ]]; then
        alias "${mnemonic}::${funct}=$new_name" 
      fi
      unset -f "$funct"
    done
  elif [[ ${#__SPM_IMPORT_STACK[@]} -eq 0 ]]; then
    local functs
    eval "functs=\${${__SPM_PACKAGES[$package_name]}[functions]}"
    eval "__=(\${${functs}["
  fi
  # Add current file to the imports of the caller package.
  if [[ ${#__SPM_IMPORT_STACK[@]} -ne 0 ]]; then
    local caller_package="${__SPM_PACKAGES[${__SPM_IMPORT_STACK[0]}]}"
    local imports_name
    eval "imports_name=\${$caller_package[imports]}"
    eval "$imports_name[$mnemonic]=\"${__SPM_PACKAGES[$package_name]}\""
  fi
}

