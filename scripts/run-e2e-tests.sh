#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# Directories
TOOLS_DIR=/tmp/e2e-tools                       # directory to store downloaded tools
NVM_DIR=${NVM_DIR:-"${HOME}/.nvm"}             # nvm installation directory
ARTIFACTS_DIR=${ARTIFACTS_DIR:-"/tmp/reports"} # directory to store generated Allure reports
TESTS_DIR=${TESTS_DIR:-""}                     # directory to use as the tests workspace; if empty, a temp dir will be created

# Versions
NODE_VERSION=${NODE_VERSION:-"lts/*"}
PLAYWRIGHT_VERSION=${PLAYWRIGHT_VERSION:-"1.57.0"} # @playwright/test version
ALLURE_VERSION=${ALLURE_VERSION:-"2.24.0"}         # Allure CLI distribution tag
ALLURE_BIN="${TOOLS_DIR}/allure-${ALLURE_VERSION}/bin/allure"

# Tests
TESTS_TARBALL=${TESTS_TARBALL:-"https://github.com/nepalevov/ai-dial-chat/archive/refs/heads/development.tar.gz"} # An URL to tar.gz with the tests source code
DOTENV_FILE=${DOTENV_FILE:-"apps/chat-e2e/.env.ci"}                                                               # Relative path inside the tests repo containing env vars to be sourced
SUITE=${TEST_SUITE:-chat}                                                                                         # Test suite to execute (chat, overlay, or nx target suffix)
KEEP_TESTS_DIR=${KEEP_TESTS_DIR:-0}                                                                               # Do not delete downloaded test workspace on exit
NX_EXTRA_ARGS=()

usage() {
  cat <<'EOF'
Usage: run-e2e-tests.sh [options] [-- extra nx args]

Options:
  --suite <name>              Test suite to execute (chat, overlay, or nx target suffix)
  --keep-tests-dir            Do not delete downloaded test workspace on exit
  --tarball <url>             An URL to tar.gz with the tests source code
  --dotenv <path>             Relative path inside the tests repo containing env vars to be sourced
  --artifacts-dir <path>      Directory where Allure reports will be written
  --help                      Show this help message

Any arguments passed after `--` are forwarded to the `npx nx run ...` command.
EOF
}

log() { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
# same as warn, but in red
error() { printf '\033[0;31m[ERROR] %s\033[0m\n' "$*" >&2; }
die() {
  error "$*"
  exit 1
}
require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
  --suite)
    [[ $# -ge 2 ]] || die "--suite requires a value"
    SUITE="$2"
    shift 2
    ;;
  --tarball)
    [[ $# -ge 2 ]] || die "--tarball requires a value"
    TESTS_TARBALL="$2"
    shift 2
    ;;
  --dotenv)
    [[ $# -ge 2 ]] || die "--dotenv requires a value"
    DOTENV_FILE="$2"
    shift 2
    ;;
  --artifacts-dir)
    [[ $# -ge 2 ]] || die "--artifacts-dir requires a value"
    ARTIFACTS_DIR="$2"
    shift 2
    ;;
  --keep-tests-dir)
    KEEP_TESTS_DIR=1
    shift
    ;;
  --help)
    usage
    exit 0
    ;;
  --)
    shift
    while [[ $# -gt 0 ]]; do
      NX_EXTRA_ARGS+=("$1")
      shift
    done
    break
    ;;
  *)
    NX_EXTRA_ARGS+=("$1")
    shift
    ;;
  esac
done

case "$SUITE" in
chat)
  NX_TARGET_DEFAULT="chat-e2e:e2e:chat"
  ALLURE_RESULTS_PATH_DEFAULT="./apps/chat-e2e/allure-chat-results"
  ;;
overlay)
  NX_TARGET_DEFAULT="chat-e2e:e2e:overlay"
  ALLURE_RESULTS_PATH_DEFAULT="./apps/chat-e2e/allure-overlay-results"
  ;;
*)
  NX_TARGET_DEFAULT="${SUITE}"
  ALLURE_RESULTS_PATH_DEFAULT="./apps/chat-e2e/allure-${SUITE}-results"
  ;;
esac

NX_TARGET=${NX_TARGET:-${NX_TARGET_DEFAULT}}
ALLURE_RESULTS_PATH=${ALLURE_RESULTS_PATH:-${ALLURE_RESULTS_PATH_DEFAULT}}

require_cmd curl
require_cmd tar

cleanup() {
  if [[ ${KEEP_TESTS_DIR} -eq 0 && -n "${TESTS_DIR}" && -d "${TESTS_DIR}" ]]; then
    rm -rf "${TESTS_DIR}"
  fi
}
trap cleanup EXIT

setup_workspace() {
  if [[ -z "${TESTS_DIR}" ]]; then
    TESTS_DIR=$(mktemp --tmpdir -d "tests.XXXXXX")
  elif [[ ${KEEP_TESTS_DIR} -eq 0 ]]; then
    rm -rf "${TESTS_DIR}"
  fi
  mkdir -p "${TESTS_DIR}"
  log "Using tests dir: ${TESTS_DIR}"
}

fetch_tests() {
  log "Downloading test sources from ${TESTS_TARBALL}"
  curl -fsSL --retry 5 --retry-delay 2 "${TESTS_TARBALL}" |
    tar -xzf - --strip-components=1 -C "${TESTS_DIR}"
}

load_nvm() {
  if [[ -s "${NVM_DIR}/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    . "${NVM_DIR}/nvm.sh"
    return 0
  fi
  warn "nvm not found in ${NVM_DIR}"
}

ensure_node() {
  if load_nvm; then
    log "Installing Node.js ${NODE_VERSION} via nvm"
    nvm install "${NODE_VERSION}" >/dev/null
    nvm use "${NODE_VERSION}" >/dev/null
    return
  fi
  if command -v node >/dev/null && command -v npm >/dev/null; then
    warn "nvm not found; falling back to system Node.js $(node --version)"
    return
  fi
  die "Node.js is not available and nvm could not be sourced"
}

ensure_java() {
  [[ -n "${JAVA_HOME:-}" ]] || die "JAVA_HOME is not set"
  command -v java >/dev/null 2>&1 || die "Java installation is not found"
}

install_allure() {
  if [[ -x "${ALLURE_BIN}" ]]; then
    log "Allure CLI already present at ${ALLURE_BIN}"
    return
  fi
  log "Installing Allure CLI ${ALLURE_VERSION}"
  mkdir -p "${TOOLS_DIR}"
  local allure_url="https://github.com/allure-framework/allure2/releases/download/${ALLURE_VERSION}/allure-${ALLURE_VERSION}.tgz"
  curl -fsSL --retry 5 --retry-delay 2 "${allure_url}" | tar -xzf - -C "${TOOLS_DIR}"
  log "Allure CLI version: $("${ALLURE_BIN}" --version)"
}

install_playwright() {
  local version
  version=$(npx --no-install playwright --version 2>/dev/null || echo "")
  if [[ "${PLAYWRIGHT_VERSION}" != "latest" && "${version}" = *"${PLAYWRIGHT_VERSION}"* ]]; then
    log "Playwright already installed with version ${version}"
    return
  fi
  log "Installing Playwright ${PLAYWRIGHT_VERSION}"
  npm install -D @playwright/test@"${PLAYWRIGHT_VERSION}" allure-playwright
  npx --no-install playwright --version
  npx playwright install --with-deps
  log "Playwright version: $(npx playwright --version)"
}

install_test_dependencies() {
  [[ -n "${SKIP_TEST_INSTALL:-}" ]] && {
    warn "SKIP_TEST_INSTALL set; skipping dependency installation"
    return
  }
  ensure_node
  ensure_java
  install_allure
  pushd "${TESTS_DIR}" >/dev/null
  install_playwright
  popd >/dev/null
}

source_dotenv() {
  local env_file="${TESTS_DIR}/${DOTENV_FILE}"
  if [[ -f "${env_file}" ]]; then
    set -a
    # shellcheck disable=SC1090
    . "${env_file}"
    set +a
  else
    warn "Dotenv file ${DOTENV_FILE} not found in ${TESTS_DIR}"
  fi
}

run_tests() {
  pushd "${TESTS_DIR}" >/dev/null
  source_dotenv
  local cmd=(npx nx run "${NX_TARGET}" --configuration=production --output-style=stream --skipInstall)
  if [[ ${#NX_EXTRA_ARGS[@]} -gt 0 ]]; then
    cmd+=("${NX_EXTRA_ARGS[@]}")
  fi
  log "Executing ${cmd[*]}"
  set +e
  "${cmd[@]}"
  TEST_EXIT_CODE=$?
  set -e
  popd >/dev/null
}

generate_report() {
  local results_dir="${TESTS_DIR}/${ALLURE_RESULTS_PATH#./}"
  if [[ ! -d "${results_dir}" ]]; then
    return 1
  fi
  mkdir -p "${ARTIFACTS_DIR}/${SUITE}"
  log "Generating Allure report for ${SUITE}"
  "${ALLURE_BIN}" generate "${results_dir}" -o "${ARTIFACTS_DIR}/${SUITE}" --clean
}

main() {
  setup_workspace
  fetch_tests
  install_test_dependencies
  run_tests
  if ! generate_report; then
    warn "Allure results directory ${ALLURE_RESULTS_PATH} not found; skipping report generation"
  fi
  if [[ -n "${TEST_EXIT_CODE:-}" ]]; then
    exit "${TEST_EXIT_CODE}"
  fi
}

main "$@"
