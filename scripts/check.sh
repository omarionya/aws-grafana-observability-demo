#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../terraform"
terraform fmt -check
terraform init -backend=false
terraform validate
python3 - <<'PYTHON'
import ast
from pathlib import Path
for path in Path('../runtime').rglob('*.py'):
    ast.parse(path.read_text(), filename=str(path))
    print('Python syntax OK:', path)
PYTHON
