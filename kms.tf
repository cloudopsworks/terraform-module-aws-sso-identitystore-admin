##
# (c) 2021-2026
#     Cloud Ops Works LLC - https://cloudops.works/
#     Find us on:
#       GitHub: https://github.com/cloudopsworks
#       WebSite: https://cloudops.works
#     Distributed Under Apache v2.0 License
#

data "aws_caller_identity" "current" {}

locals {
  partition = split(":", data.aws_caller_identity.current.arn)[1]
  # coalesce/compact also treat keys left empty in inputs.yaml (null) as unset.
  encryption_input_kms_key_arn = try(coalesce(var.encryption.kms_key_arn), "")
  create_kms_key               = local.encryption_enabled && local.encryption_input_kms_key_arn == ""
  kms_admin_account_ids = concat(
    [data.aws_caller_identity.current.account_id],
    compact(flatten([try(var.encryption.delegated_admin_account_ids, [])]))
  )
  kms_key_rotation = try(var.encryption.enable_key_rotation, true) != false
  kms_multi_region = try(var.encryption.multi_region, false) == true
  kms_replica_regions = local.create_kms_key && local.kms_multi_region ? toset(
    compact(flatten([try(var.encryption.replica_regions, [])]))
  ) : toset([])
  kms_service_principals = [
    "identitystore.amazonaws.com",
    "sso.amazonaws.com",
  ]
  kms_via_services = [
    "sso.*.amazonaws.com",
    "identitystore.*.amazonaws.com",
  ]
  kms_encryption_context_keys = [
    "aws:sso:instance-arn",
    "aws:identitystore:identitystore-arn",
  ]
}

# IAM Identity Center baseline KMS key policy, plus the Terraform identity administering the instance:
# https://docs.aws.amazon.com/singlesignon/latest/userguide/baseline-KMS-key-policy.html
data "aws_iam_policy_document" "kms" {
  count = local.create_kms_key ? 1 : 0
  statement {
    sid       = "AllowIdentityCenterAdminAccounts"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [for account_id in local.kms_admin_account_ids : "arn:${local.partition}:iam::${account_id}:root"]
    }
  }
  statement {
    sid       = "AllowIdentityCenterAndIdentityStoreToDescribeKey"
    effect    = "Allow"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = local.kms_service_principals
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = ["&{aws:ResourceAccount}"]
    }
  }
  statement {
    sid    = "AllowIdentityCenterAndIdentityStoreToUseKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:ReEncryptTo",
      "kms:ReEncryptFrom",
      "kms:GenerateDataKeyWithoutPlaintext",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = local.kms_service_principals
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = ["&{aws:ResourceAccount}"]
    }
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:EncryptionContextKeys"
      values   = local.kms_encryption_context_keys
    }
  }
  statement {
    sid       = "AllowOrgPrincipalsViaIdentityCenterAndIdentityStore"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalOrgID"
      values   = ["&{aws:ResourceOrgID}"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = local.kms_via_services
    }
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:EncryptionContextKeys"
      values   = local.kms_encryption_context_keys
    }
  }
  # Identity Center uses the key with the forward access session of the principal calling its APIs: the identity
  # Terraform runs as configures the instance (UpdateInstance) and manages its users and groups, so it is granted the
  # key here, through Identity Center and Identity Store only, and needs no identity-based KMS policy.
  statement {
    sid    = "AllowTerraformIdentityCenterAdministration"
    effect = "Allow"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKeyWithoutPlaintext",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = [local.encryption_provider_principal_arn]
    }
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = local.kms_via_services
    }
  }
  statement {
    sid       = "AllowManagedApps"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:PrincipalIsAWSService"
      values   = ["true"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceOrgID"
      values   = ["&{aws:ResourceOrgID}"]
    }
    condition {
      test     = "StringLike"
      variable = "kms:ViaService"
      values   = local.kms_via_services
    }
    condition {
      test     = "ForAnyValue:StringEquals"
      variable = "kms:EncryptionContextKeys"
      values   = local.kms_encryption_context_keys
    }
  }
}

resource "aws_kms_key" "this" {
  count                   = local.create_kms_key ? 1 : 0
  description             = "IAM Identity Center at-rest encryption key - ${local.system_name}"
  deletion_window_in_days = try(coalesce(var.encryption.deletion_window_in_days), 30)
  multi_region            = local.kms_multi_region
  enable_key_rotation     = local.kms_key_rotation
  rotation_period_in_days = local.kms_key_rotation ? try(coalesce(var.encryption.rotation_period_in_days), 90) : null
  policy                  = data.aws_iam_policy_document.kms[0].json
  tags                    = local.all_tags
}

resource "aws_kms_alias" "this" {
  count         = local.create_kms_key ? 1 : 0
  name          = "alias/identity-store-${local.system_name}"
  target_key_id = aws_kms_key.this[0].key_id
}

# Replicas of the multi-Region key, for IAM Identity Center replicated to other regions. They carry the primary key
# policy, as AWS recommends the same policy across replicas, and the same alias in their region.
resource "aws_kms_replica_key" "this" {
  for_each                = local.kms_replica_regions
  region                  = each.value
  primary_key_arn         = aws_kms_key.this[0].arn
  description             = aws_kms_key.this[0].description
  deletion_window_in_days = aws_kms_key.this[0].deletion_window_in_days
  policy                  = data.aws_iam_policy_document.kms[0].json
  tags                    = merge(local.all_tags, {
    "replica" = "true"
    "replica-region" = each.value
    "primary-region" = data.aws_region.current.region
  })
  lifecycle {
    precondition {
      condition     = each.value != data.aws_region.current.region
      error_message = "encryption.replica_regions must not include the primary key region (${data.aws_region.current.region})."
    }
  }
}

resource "aws_kms_alias" "replica" {
  for_each      = aws_kms_replica_key.this
  region        = each.key
  name          = aws_kms_alias.this[0].name
  target_key_id = each.value.key_id
}
