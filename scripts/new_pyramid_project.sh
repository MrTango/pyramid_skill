#!/usr/bin/env bash
#
# new_pyramid_project.sh — scaffold a Pyramid project with the official
# cookiecutter starter into a fresh virtualenv, ready to run.
#
# Usage:
#   scripts/new_pyramid_project.sh [TARGET_DIR]
#
# TARGET_DIR defaults to the current directory. The script creates ./env,
# installs cookiecutter, runs the interactive starter (you pick template
# language / backend / routing), then installs the generated project editable
# with its [testing] extra.
#
set -euo pipefail

TARGET_DIR="${1:-.}"
mkdir -p "$TARGET_DIR"
cd "$TARGET_DIR"

PY="${PYTHON:-python3}"

echo ">> Creating virtualenv in ./env"
"$PY" -m venv env
./env/bin/pip install --upgrade pip setuptools cookiecutter

echo ">> Running pyramid-cookiecutter-starter (answer the prompts)"
./env/bin/cookiecutter gh:Pylons/pyramid-cookiecutter-starter --checkout main

# Find the generated project dir: the newest dir containing a setup.py/pyproject.
PROJ="$(find . -maxdepth 2 -name 'setup.py' -o -maxdepth 2 -name 'pyproject.toml' 2>/dev/null \
        | sed 's#/[^/]*$##' | grep -v '/env' | sort -u | tail -n1 || true)"

if [[ -z "${PROJ}" ]]; then
  echo "!! Could not auto-detect the generated project directory."
  echo "   cd into it and run: ../env/bin/pip install -e '.[testing]'"
  exit 0
fi

echo ">> Installing generated project: ${PROJ}"
( cd "$PROJ" && ../env/bin/pip install -e ".[testing]" )

cat <<EOF

Done. Next steps:

  cd ${TARGET_DIR%/}/${PROJ#./}
  ../env/bin/initialize_db development.ini      # only if you chose the SQLAlchemy backend
  ../env/bin/pserve development.ini --reload    # http://localhost:6543
  ../env/bin/pytest -q
EOF
