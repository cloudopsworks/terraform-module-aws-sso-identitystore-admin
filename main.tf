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
  # UpdateInstance attempts, covering the propagation of a just-created key policy.
  encryption_update_attempts = 5
  # Sets KEY_TYPE (and KMS_KEY_ARN) on the instance and waits for the re-encryption. The AWS CLI runs outside the
  # provider, with the shell's credentials. When those are not already the provider identity, the provider's role is
  # assumed first, so an assume_role provider configuration is honoured.
  encryption_script = <<-EOT
    set -e
    CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
    if [ "$CALLER_ARN" != "$PROVIDER_ARN" ]; then
      case "$CALLER_ARN" in
        "$PROVIDER_ROLE_SESSION_PREFIX"*) ;;
        *)
          if [ -z "$PROVIDER_ROLE_ARN" ]; then
            echo "AWS CLI identity $CALLER_ARN differs from the provider identity $PROVIDER_ARN, which is not an assumed role." >&2
            exit 1
          fi
          CREDENTIALS=$(aws sts assume-role --role-arn "$PROVIDER_ROLE_ARN" --role-session-name "$ROLE_SESSION_NAME" \
            --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text)
          set -- $CREDENTIALS
          if [ -z "$3" ]; then
            echo "Could not assume $PROVIDER_ROLE_ARN." >&2
            exit 1
          fi
          unset AWS_PROFILE AWS_DEFAULT_PROFILE
          export AWS_ACCESS_KEY_ID="$1" AWS_SECRET_ACCESS_KEY="$2" AWS_SESSION_TOKEN="$3"
          ;;
      esac
    fi
    # Sets STATUS and KEY. An instance never moved off the default reports no encryption details: the AWS owned key.
    read_encryption() {
      DETAILS=$(aws sso-admin describe-instance --region "$REGION" --instance-arn "$INSTANCE_ARN" \
        --query 'EncryptionConfigurationDetails.[EncryptionStatus,KeyType,KmsKeyArn]' --output text) || exit 1
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
    until aws sso-admin update-instance --region "$REGION" --instance-arn "$INSTANCE_ARN" --encryption-configuration "$CONFIG"; do
      if [ "$ATTEMPT" -ge "$UPDATE_ATTEMPTS" ]; then
        echo "UpdateInstance failed $ATTEMPT times for $INSTANCE_ARN." >&2
        exit 1
      fi
      ATTEMPT=$((ATTEMPT + 1))
      sleep "$POLL_SECONDS"
    done
    # Gives DescribeInstance time to report the update before polling it.
    sleep "$POLL_SECONDS"
    wait_settled
    if [ "$STATUS" != "ENABLED" ] || [ "$KEY" != "$KEY_TYPE" ]; then
      REASON=$(aws sso-admin describe-instance --region "$REGION" --instance-arn "$INSTANCE_ARN" \
        --query 'EncryptionConfigurationDetails.EncryptionStatusReason' --output text) || REASON="unknown"
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
}

# Resolves the IAM role behind the provider credentials (issuer_arn keeps the role path), so the CLI can run as it.
data "aws_iam_session_context" "current" {
  count = local.encryption_enabled ? 1 : 0
  arn   = data.aws_caller_identity.current.arn
}

locals {
  # Neither AWS::SSO::Instance (awscc) nor the AWS provider expose the instance encryption configuration, so it is
  # set through the AWS CLI. Kept in terraform_data input, out of triggers_replace, so a credential or script change
  # alone does not re-run the CLI.
  encryption_cli = local.encryption_enabled ? {
    script = local.encryption_script
    environment = {
      INSTANCE_ARN    = awscc_sso_instance.this[0].instance_arn
      REGION          = data.aws_region.current.region
      POLL_SECONDS    = local.encryption_poll_seconds
      TIMEOUT_SECONDS = local.encryption_timeout_seconds
      UPDATE_ATTEMPTS = local.encryption_update_attempts
      # Only an identity that is not an assumed role is compared verbatim: session names may change on every run.
      PROVIDER_ARN      = data.aws_iam_session_context.current[0].issuer_name == "" ? data.aws_caller_identity.current.arn : ""
      PROVIDER_ROLE_ARN = data.aws_iam_session_context.current[0].issuer_name != "" ? data.aws_iam_session_context.current[0].issuer_arn : ""
      PROVIDER_ROLE_SESSION_PREFIX = format("arn:%s:sts::%s:assumed-role/%s/",
        local.partition,
        data.aws_caller_identity.current.account_id,
        data.aws_iam_session_context.current[0].issuer_name
      )
      ROLE_SESSION_NAME = "sso-instance-encryption"
    }
  } : null
}

# Destroy-only guard: moves the instance back to the AWS owned key when encryption is disabled or the key changes,
# and waits for it. Having no create provisioner, it is never tainted, so the revert always runs; depending on the
# module-created key, it finishes before that key is scheduled for deletion.
resource "terraform_data" "encryption_guard" {
  count = local.encryption_enabled ? 1 : 0
  triggers_replace = {
    instance_arn = awscc_sso_instance.this[0].instance_arn
    region       = data.aws_region.current.region
    kms_key_arn  = local.encryption_kms_key_arn
  }
  input = local.encryption_cli

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
