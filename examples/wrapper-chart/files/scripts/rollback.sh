#!/bin/bash
set -euo pipefail

echo "=== Rollback Task ==="
echo "Submitter : $AQSH_SUBMITTER"
echo "Version   : $VERSION"

# Add your actual rollback logic here
# e.g. kubectl rollout undo deployment/my-app -n production

cat > "$AQSH_RESULT_FILE" <<EOF
{
  "rolled_back_to": "$VERSION",
  "submitter": "$AQSH_SUBMITTER"
}
EOF
