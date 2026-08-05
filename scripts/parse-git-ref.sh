#!/usr/bin/env bash
# Parses a git ref string into GIT_URL, GIT_REF, and GIT_PATH.
#
# Input:  $1 — ref string in format: URL[.git@revision][#path]
# Output: GIT_URL, GIT_REF, GIT_PATH (exported)

parse_git_ref() {
  local ref="$1"
  GIT_PATH="${ref#*#}"
  local full_url="${ref%%#*}"
  [[ "${GIT_PATH}" == "${ref}" ]] && GIT_PATH="."

  if [[ "${full_url}" == *".git@"* ]]; then
    GIT_URL="${full_url%@*}"
    GIT_REF="${full_url##*.git@}"
  elif [[ "${full_url}" =~ ^(https://[^@]+)@([^@]+)$ ]]; then
    GIT_URL="${BASH_REMATCH[1]}"
    GIT_REF="${BASH_REMATCH[2]}"
  else
    GIT_URL="${full_url}"
    GIT_REF="main"
  fi
  GIT_URL="${GIT_URL%.git}"
  export GIT_URL GIT_REF GIT_PATH
}
