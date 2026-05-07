#!/bin/bash
set -euo pipefail

echo "=== Deploy Task ==="
echo "Submitter : $AQSH_SUBMITTER"
echo "Version   : $VERSION"
echo "Environment: $ENVIRONMENT"

# Add your actual deploy logic here
# e.g. kubectl set image deployment/my-app my-app=my-image:$VERSION -n $ENVIRONMENT

# Write structured result (optional)
cat > "$AQSH_RESULT_FILE" <<EOF
{
  "deployed_version": "$VERSION",
  "environment": "$ENVIRONMENT",
  "submitter": "$AQSH_SUBMITTER"
}
EOF
