
name: Configure Nginx on EC2

on:
  workflow_dispatch:

permissions:
  contents: read

concurrency:
  group: configure-nginx-ec2
  cancel-in-progress: false

jobs:
  configure-nginx:
    runs-on: ubuntu-latest
    timeout-minutes: 20

    env:
      AWS_REGION: us-east-1
      EC2_INSTANCE_ID: ${{ vars.EC2_INSTANCE_ID }}
      NGINX_LISTEN_PORT: "80"

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Validate configuration
        shell: bash
        run: |
          set -euo pipefail

          [[ "$EC2_INSTANCE_ID" =~ ^i-[0-9a-f]{8,17}$ ]] || {
            echo "::error::EC2_INSTANCE_ID is missing or invalid."
            exit 1
          }

          [[ -f ec2/configure-nginx.sh ]] || {
            echo "::error::configure-nginx.sh was not found."
            exit 1
          }

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-session-token: ${{ secrets.AWS_SESSION_TOKEN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Verify AWS and SSM access
        shell: bash
        run: |
          set -euo pipefail

          aws sts get-caller-identity

          aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$EC2_INSTANCE_ID" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text

      - name: Prepare remote script
        id: prepare
        shell: bash
        run: |
          set -euo pipefail

          SCRIPT_B64="$(gzip -c ec2/configure-nginx.sh | base64 -w0)"

          REMOTE_COMMAND="set -eu; remote_script=\$(mktemp /tmp/configure-nginx.XXXXXX); trap 'rm -f -- \"\$remote_script\"' EXIT; printf '%s' '$SCRIPT_B64' | base64 --decode | gzip --decompress > \"\$remote_script\"; chmod 700 \"\$remote_script\"; sudo env NGINX_LISTEN_PORT='$NGINX_LISTEN_PORT' bash \"\$remote_script\""

          jq -n \
            --arg command "$REMOTE_COMMAND" \
            '{commands: [$command], executionTimeout: ["900"]}' \
            > "$RUNNER_TEMP/ssm-parameters.json"

      - name: Execute Nginx configuration through SSM
        id: ssm
        shell: bash
        run: |
          set -euo pipefail

          COMMAND_ID="$(aws ssm send-command \
            --instance-ids "$EC2_INSTANCE_ID" \
            --document-name AWS-RunShellScript \
            --comment "Configure Nginx reverse proxy" \
            --timeout-seconds 900 \
            --parameters "file://$RUNNER_TEMP/ssm-parameters.json" \
            --region "$AWS_REGION" \
            --query 'Command.CommandId' \
            --output text)"

          [[ "$COMMAND_ID" =~ ^[0-9a-f-]{36}$ ]] || {
            echo "::error::SSM did not return a valid command ID."
            exit 1
          }

          echo "command_id=$COMMAND_ID" >> "$GITHUB_OUTPUT"

          for attempt in $(seq 1 90); do
            STATUS="$(aws ssm get-command-invocation \
              --command-id "$COMMAND_ID" \
              --instance-id "$EC2_INSTANCE_ID" \
              --region "$AWS_REGION" \
              --query 'Status' \
              --output text 2>/dev/null || true)"

            case "$STATUS" in
              Success)
                echo "Nginx configuration completed successfully."
                aws ssm get-command-invocation \
                  --command-id "$COMMAND_ID" \
                  --instance-id "$EC2_INSTANCE_ID" \
                  --region "$AWS_REGION" \
                  --query 'StandardOutputContent' \
                  --output text
                exit 0
                ;;
              Failed|Cancelled|TimedOut|Cancelling)
                echo "::error::SSM command finished with status: $STATUS"
                aws ssm get-command-invocation \
                  --command-id "$COMMAND_ID" \
                  --instance-id "$EC2_INSTANCE_ID" \
                  --region "$AWS_REGION" \
                  --query '[StandardOutputContent,StandardErrorContent]' \
                  --output text || true
                exit 1
                ;;
              *)
                sleep 10
                ;;
            esac
          done

          echo "::error::Timed out waiting for SSM command completion."
          exit 1
