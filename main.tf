##
# (c) 2021-2026
#     Cloud Ops Works LLC - https://cloudops.works/
#     Find us on:
#       GitHub: https://github.com/cloudopsworks
#       WebSite: https://cloudops.works
#     Distributed Under Apache v2.0 License
#

locals {
  sso_instance_arn       = data.aws_ssoadmin_instances.sso.arns[0]
  encryption_enabled     = var.is_hub && try(tobool(var.encryption.enabled), false) == true
  encryption_kms_key_arn = local.create_kms_key ? one(aws_kms_key.this[*].arn) : local.encryption_input_kms_key_arn
  # UpdateInstance re-encrypts asynchronously (EncryptionStatus UPDATING -> ENABLED | UPDATE_FAILED), polled until settled.
  encryption_poll_seconds = 15
  # Bounds each wait. A timeout, like credentials expiring during a long wait, only fails the run: the forward update
  # is retried by the next apply, and a failed revert keeps the key.
  encryption_timeout_seconds = 3000
  # UpdateInstance attempts, covering the propagation of a just-created or just-updated key policy.
  encryption_update_attempts = 12
  # Sets KEY_TYPE (and KMS_KEY_ARN) on the instance and waits for the re-encryption. The AWS CLI runs outside the
  # provider, so it is given the provider identity: the shell's credentials when they already are that identity, else
  # temporary credentials of the provider role (assume_role), assumed from them and verified. The shell's credentials
  # are never replaced, so the role can be assumed again when its session expires during a long wait.
  encryption_script = <<-EOT
    set -e
    provider_identity() {
      ASSUMED=""
      CALLER_ARN=$(aws sts get-caller-identity --region "$REGION" --query Arn --output text) || exit 1
      if [ "$CALLER_ARN" = "$PROVIDER_ARN" ]; then return 0; fi
      if [ -z "$PROVIDER_ROLE_ARN" ]; then
        echo "AWS CLI identity $CALLER_ARN is not the provider identity $PROVIDER_ARN, which is not a role to assume." >&2
        exit 1
      fi
      case "$CALLER_ARN" in "$PROVIDER_ROLE_SESSION_PREFIX"*) return 0 ;; esac
      set -- --region "$REGION" --role-arn "$PROVIDER_ROLE_ARN" --role-session-name "$ROLE_SESSION_NAME"
      if [ -n "$EXTERNAL_ID" ]; then set -- "$@" --external-id "$EXTERNAL_ID"; fi
      CREDENTIALS=$(aws sts assume-role "$@" \
        --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text) || exit 1
      set -- $CREDENTIALS
      if [ -z "$3" ]; then
        echo "Could not assume $PROVIDER_ROLE_ARN from $CALLER_ARN." >&2
        exit 1
      fi
      ROLE_ACCESS_KEY_ID=$1 ROLE_SECRET_ACCESS_KEY=$2 ROLE_SESSION_TOKEN=$3 ASSUMED=1
      ROLE_CALLER_ARN=$(provider_aws sts get-caller-identity --region "$REGION" --query Arn --output text) || exit 1
      case "$ROLE_CALLER_ARN" in
        "$PROVIDER_ROLE_SESSION_PREFIX"*) ;;
        *)
          echo "Assumed identity $ROLE_CALLER_ARN is not the provider role $PROVIDER_ROLE_ARN." >&2
          exit 1
          ;;
      esac
    }
    # The role credentials are exported in a subshell, so they never show in a process command line, and settings
    # describing the shell credentials (profile, expiration) do not apply to them.
    provider_aws() {
      if [ -n "$ASSUMED" ]; then
        (
          unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_CREDENTIAL_EXPIRATION AWS_SECURITY_TOKEN
          export AWS_ACCESS_KEY_ID="$ROLE_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$ROLE_SECRET_ACCESS_KEY" \
            AWS_SESSION_TOKEN="$ROLE_SESSION_TOKEN"
          exec aws "$@"
        )
      else
        aws "$@"
      fi
    }
    describe() {
      provider_aws sso-admin describe-instance --region "$REGION" --instance-arn "$INSTANCE_ARN" --query "$1" --output text
    }
    provider_identity
    # Sets STATUS and KEY. An instance never moved off the default reports no encryption details: the AWS owned key.
    # A failed read is retried once with a fresh provider identity, in case the role session expired.
    read_encryption() {
      DETAILS=$(describe 'EncryptionConfigurationDetails.[EncryptionStatus,KeyType,KmsKeyArn]') || {
        provider_identity
        DETAILS=$(describe 'EncryptionConfigurationDetails.[EncryptionStatus,KeyType,KmsKeyArn]') || exit 1
      }
      set -- $DETAILS None None None
      STATUS=$1 KEY=$2 KEY_ARN=$3
      if [ "$STATUS" = "None" ]; then STATUS="ENABLED"; fi
      if [ "$KEY" = "None" ]; then KEY="AWS_OWNED_KMS_KEY"; fi
    }
    wait_settled() {
      ELAPSED=0
      read_encryption
      while [ "$STATUS" = "UPDATING" ]; do
        if [ "$ELAPSED" -ge "$TIMEOUT_SECONDS" ]; then
          echo "Timed out after $ELAPSED seconds waiting for the encryption update of $INSTANCE_ARN." >&2
          exit 1
        fi
        sleep "$POLL_SECONDS"
        ELAPSED=$((ELAPSED + POLL_SECONDS))
        read_encryption
      done
    }
    wait_settled
    if [ "$STATUS" = "ENABLED" ] && [ "$KEY" = "$KEY_TYPE" ] && { [ -z "$KMS_KEY_ARN" ] || [ "$KEY_ARN" = "$KMS_KEY_ARN" ]; }; then
      echo "$INSTANCE_ARN already uses $KEY_TYPE $KMS_KEY_ARN."
      exit 0
    fi
    CONFIG="KeyType=$KEY_TYPE"
    if [ -n "$KMS_KEY_ARN" ]; then CONFIG="$CONFIG,KmsKeyArn=$KMS_KEY_ARN"; fi
    ATTEMPT=1
    until provider_aws sso-admin update-instance --region "$REGION" --instance-arn "$INSTANCE_ARN" --encryption-configuration "$CONFIG"; do
      if [ "$ATTEMPT" -ge "$UPDATE_ATTEMPTS" ]; then
        echo "UpdateInstance failed $ATTEMPT times for $INSTANCE_ARN." >&2
        exit 1
      fi
      ATTEMPT=$((ATTEMPT + 1))
      sleep "$POLL_SECONDS"
      provider_identity
    done
    # Gives DescribeInstance time to report the update before polling it.
    sleep "$POLL_SECONDS"
    wait_settled
    if [ "$STATUS" != "ENABLED" ] || [ "$KEY" != "$KEY_TYPE" ]; then
      REASON=$(describe 'EncryptionConfigurationDetails.EncryptionStatusReason') || REASON="unknown"
      echo "Encryption update of $INSTANCE_ARN to $KEY_TYPE ended $STATUS with $KEY: $REASON" >&2
      exit 1
    fi
  EOT
}

data "aws_ssoadmin_instances" "sso" {}

# The hub (management account) owns the organization instance: adopt it into state instead of creating one.
import {
  for_each = var.is_hub ? toset([local.sso_instance_arn]) : toset([])
  id       = each.value
  to       = awscc_sso_instance.this[0]
}

# Name and tags are left as they are. The organization instance holds every user, group and assignment, and its
# delete handler calls DeleteInstance, so destroy is refused. To stop managing it, set is_hub to false and remove it
# from state in the same change (terragrunt state rm 'awscc_sso_instance.this[0]'): while is_hub is true, the import
# block adopts it again.
resource "awscc_sso_instance" "this" {
  count = var.is_hub ? 1 : 0
  lifecycle {
    prevent_destroy = true
  }
}

check "encryption_hub_only" {
  assert {
    condition     = var.is_hub || try(tobool(var.encryption.enabled), false) != true
    error_message = "encryption.enabled is ignored: at-rest encryption is applied only by the hub deployment (is_hub: true) that owns the organization instance."
  }
  assert {
    condition     = local.encryption_input_kms_key_arn == "" || length(compact(flatten([try(var.encryption.replica_regions, [])]))) == 0
    error_message = "encryption.replica_regions is ignored with encryption.kms_key_arn: only a module-created key is replicated."
  }
}

# Resolves the IAM role behind the provider credentials (issuer_arn keeps the role path), so the CLI can run as it,
# unless encryption.assume_role.role_arn names it.
data "aws_iam_session_context" "current" {
  count = local.encryption_enabled && local.encryption_cli_role_arn == "" ? 1 : 0
  arn   = data.aws_caller_identity.current.arn
}

locals {
  # Neither AWS::SSO::Instance (awscc) nor the AWS provider expose the instance encryption configuration, so it is
  # set through the AWS CLI. Kept in terraform_data input, out of triggers_replace, so a credential or script change
  # alone does not re-run the CLI.
  encryption_cli_role_arn = try(coalesce(var.encryption.assume_role.role_arn), "")
  # Role the CLI runs as: encryption.assume_role.role_arn, else the role behind the provider credentials; "" when the
  # provider identity is not an assumed role (IAM user), which the CLI then has to match exactly.
  encryption_provider_role_arn = local.encryption_cli_role_arn != "" ? local.encryption_cli_role_arn : try(
    data.aws_iam_session_context.current[0].issuer_name != "" ? data.aws_iam_session_context.current[0].issuer_arn : "",
    ""
  )
  encryption_provider_role_session_prefix = local.encryption_provider_role_arn == "" ? "" : format("arn:%s:sts::%s:assumed-role/%s/",
    split(":", local.encryption_provider_role_arn)[1],
    split(":", local.encryption_provider_role_arn)[4],
    reverse(split("/", local.encryption_provider_role_arn))[0]
  )
  # IAM principal the provider runs as, granted use of the module-created key.
  encryption_provider_principal_arn = local.encryption_provider_role_arn != "" ? local.encryption_provider_role_arn : data.aws_caller_identity.current.arn
  encryption_cli = local.encryption_enabled ? {
    script = local.encryption_script
    environment = {
      INSTANCE_ARN    = awscc_sso_instance.this[0].instance_arn
      REGION          = data.aws_region.current.region
      POLL_SECONDS    = local.encryption_poll_seconds
      TIMEOUT_SECONDS = local.encryption_timeout_seconds
      UPDATE_ATTEMPTS = local.encryption_update_attempts
      # Only an identity that is not an assumed role is compared verbatim; a role matches on any of its sessions, as
      # session names may change on every run.
      PROVIDER_ARN                 = local.encryption_provider_role_arn == "" ? data.aws_caller_identity.current.arn : ""
      PROVIDER_ROLE_ARN            = local.encryption_provider_role_arn
      PROVIDER_ROLE_SESSION_PREFIX = local.encryption_provider_role_session_prefix
      EXTERNAL_ID                  = try(coalesce(var.encryption.assume_role.external_id), "")
      ROLE_SESSION_NAME            = try(coalesce(var.encryption.assume_role.session_name), "sso-instance-encryption")
    }
  } : null
}

# Destroy-only guard: moves the instance back to the AWS owned key when encryption is disabled or the key changes,
# and waits for it. Having no create provisioner, it is never tainted, so the revert always runs; depending on the
# module-created key and its replicas, it finishes before they are scheduled for deletion, and the replicas exist
# before the instance moves to the key.
resource "terraform_data" "encryption_guard" {
  count      = local.encryption_enabled ? 1 : 0
  depends_on = [aws_kms_replica_key.this]
  triggers_replace = {
    instance_arn = awscc_sso_instance.this[0].instance_arn
    region       = data.aws_region.current.region
    kms_key_arn  = local.encryption_kms_key_arn
  }
  input = local.encryption_cli

  lifecycle {
    precondition {
      condition     = local.encryption_cli_role_arn == "" || startswith(data.aws_caller_identity.current.arn, local.encryption_provider_role_session_prefix)
      error_message = "encryption.assume_role.role_arn must be the role the provider runs as (${data.aws_caller_identity.current.arn}), so the CLI keeps the provider auth context."
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/sh", "-c"]
    command     = self.input.script
    environment = merge(self.input.environment, {
      KEY_TYPE    = "AWS_OWNED_KMS_KEY"
      KMS_KEY_ARN = ""
    })
  }
}

# Moves the instance to the KMS key and waits for the re-encryption. A failure only taints this resource, and the
# next apply retries it.
resource "terraform_data" "encryption" {
  count = local.encryption_enabled ? 1 : 0
  triggers_replace = merge(terraform_data.encryption_guard[0].triggers_replace, {
    guard_id = terraform_data.encryption_guard[0].id
  })
  input = local.encryption_cli

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = self.input.script
    environment = merge(self.input.environment, {
      KEY_TYPE    = "CUSTOMER_MANAGED_KEY"
      KMS_KEY_ARN = self.triggers_replace.kms_key_arn
    })
  }
}

resource "aws_identitystore_group" "group" {
  for_each          = { for g in var.groups : g.display_name => g }
  identity_store_id = data.aws_ssoadmin_instances.sso.identity_store_ids[0]
  display_name      = each.value.display_name
  description       = try(each.value.description, "Managed by Terraform")
}

data "aws_identitystore_user" "user" {
  for_each          = { for u in var.users : u.user_name => u if try(u.provisioned, false) }
  identity_store_id = data.aws_ssoadmin_instances.sso.identity_store_ids[0]
  alternate_identifier {
    unique_attribute {
      attribute_path  = "UserName"
      attribute_value = each.value.user_name
    }
  }
}

resource "aws_identitystore_user" "user" {
  for_each          = { for u in var.users : u.user_name => u if try(u.provisioned, false) == false }
  identity_store_id = data.aws_ssoadmin_instances.sso.identity_store_ids[0]
  user_name         = each.value.user_name
  display_name      = try(each.value.display_name, "${each.value.first_name} ${each.value.last_name}")
  name {
    given_name  = each.value.first_name
    family_name = each.value.last_name
  }
  dynamic "emails" {
    for_each = try(each.value.emails, [])
    content {
      value   = emails.value.email
      primary = try(emails.value.primary, null)
      type    = try(emails.value.type, null)
    }
  }
  dynamic "addresses" {
    for_each = try(each.value.addresses, [])
    content {
      street_address = addresses.value.address_line
      formatted      = try(addresses.value.formatted, null)
      locality       = addresses.value.city
      region         = addresses.value.region
      postal_code    = addresses.value.postal_code
      type           = try(addresses.value.type, null)
    }
  }
}

resource "aws_identitystore_group_membership" "group_membership" {
  for_each = merge(
    [
      for u in var.users : {
        for g in u.groups : "${u.user_name}-${g}" => {
          user_name  = u.user_name
          group_name = g
        }
      } if try(u.provisioned, false) == false
    ]...
  )
  identity_store_id = data.aws_ssoadmin_instances.sso.identity_store_ids[0]
  group_id          = aws_identitystore_group.group[each.value.group_name].group_id
  member_id         = aws_identitystore_user.user[each.value.user_name].user_id

}

resource "aws_identitystore_group_membership" "provisioned_group_membership" {
  for_each = merge(
    [
      for u in var.users : {
        for g in u.groups : "${u.user_name}-${g}" => {
          user_name  = u.user_name
          group_name = g
        }
      } if try(u.provisioned, false)
    ]...
  )
  identity_store_id = data.aws_ssoadmin_instances.sso.identity_store_ids[0]
  group_id          = aws_identitystore_group.group[each.value.group_name].group_id
  member_id         = data.aws_identitystore_user.user[each.value.user_name].id

}
