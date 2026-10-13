##
# (c) 2021-2026
#     Cloud Ops Works LLC - https://cloudops.works/
#     Find us on:
#       GitHub: https://github.com/cloudopsworks
#       WebSite: https://cloudops.works
#     Distributed Under Apache v2.0 License
#

output "identity_store_id" {
  description = "ID of the IAM Identity Center identity store resolved from the first SSO instance."
  value       = data.aws_ssoadmin_instances.sso.identity_store_ids[0]
}

output "identity_store_arn" {
  description = "ARN of the IAM Identity Center (SSO) instance that owns the identity store."
  value       = data.aws_ssoadmin_instances.sso.arns[0]
}

output "users" {
  description = "Map of users created by this module, keyed by user_name, with id, user_name and display_name."
  value = {
    for u in aws_identitystore_user.user : u.user_name => {
      id           = u.user_id
      user_name    = u.user_name
      display_name = u.display_name
    }
  }
}

output "groups" {
  description = "Map of groups created by this module, keyed by display_name, with id and display_name."
  value = {
    for g in aws_identitystore_group.group : g.display_name => {
      id           = g.group_id
      display_name = g.display_name
    }
  }
}

output "kms_key_arn" {
  description = "ARN of the customer managed KMS key encrypting the IAM Identity Center instance (module-created or provided); null when encryption is not managed."
  value       = local.encryption_enabled ? local.encryption_kms_key_arn : null
}

output "kms_replica_key_arns" {
  description = "Map of region to ARN of the multi-Region KMS key replicas created by this module; empty when none."
  value       = { for region, replica in aws_kms_replica_key.this : region => replica.arn }
}

output "kms_key_alias" {
  description = "Alias of the KMS key created by this module for the IAM Identity Center instance; null when no key is created."
  value       = one(aws_kms_alias.this[*].name)
}
