##
# (c) 2021-2026
#     Cloud Ops Works LLC - https://cloudops.works/
#     Find us on:
#       GitHub: https://github.com/cloudopsworks
#       WebSite: https://cloudops.works
#     Distributed Under Apache v2.0 License
#

## YAML Format
# users:                                # (Optional) List of users to create or reference in the identity store. Default: []
#   - user_name: "user@example.com"     # (Required) Unique user name, typically the email/UPN. Used to look up provisioned users.
#     first_name: "Jane"                # (Required when provisioned: false) Given name of the user.
#     last_name: "Doe"                  # (Required when provisioned: false) Family name of the user.
#     display_name: "Jane Doe"          # (Optional) Display name. Default: "<first_name> <last_name>".
#     provisioned: false                # (Optional) true = user already exists (e.g. SCIM/IdP), only memberships are managed;
#                                       #            false = user is created by this module. Default: false
#     emails:                           # (Optional) List of email addresses. Ignored when provisioned: true. Default: []
#       - email: "user@example.com"     # (Required) Email address.
#         primary: true                 # (Optional) Whether this is the primary email. Default: null
#         type: "work"                  # (Optional) Email type, free-form (e.g. work, home, other). Default: null
#     addresses:                        # (Optional) List of postal addresses. Ignored when provisioned: true. Default: []
#       - address_line: "123 Main St"   # (Required) Street address.
#         city: "Seattle"               # (Required) Locality / city.
#         region: "WA"                  # (Required) Region / state.
#         postal_code: "98101"          # (Required) Postal code.
#         formatted: "123 Main St, Seattle, WA 98101" # (Optional) Full formatted address. Default: null
#         type: "work"                  # (Optional) Address type, free-form (e.g. work, home). Default: null
#     groups:                           # (Required) List of group display_names (declared in `groups`) the user belongs to; use [] for none.
#       - "Admins"
variable "users" {
  description = "(Optional) List of users to create (provisioned: false) or reference (provisioned: true) in the identity store, with their group memberships. Default: []"
  type        = any
  default     = []
}

## YAML Format
# groups:                               # (Optional) List of groups to create in the identity store. Default: []
#   - display_name: "Admins"            # (Required) Unique group display name; referenced by users[].groups.
#     description: "Admins group"       # (Optional) Group description. Default: "Managed by Terraform"
variable "groups" {
  description = "(Optional) List of groups to create in the identity store. Default: []"
  type        = any
  default     = []
}

## YAML Format
# encryption:                           # (Optional) At-rest encryption of the IAM Identity Center instance with a customer managed KMS key.
#                                       #            Applied only when is_hub: true (organization instance, management account). Default: {}
#   enabled: false                      # (Optional) true = encrypt with a customer managed KMS key; false = keep the instance on the
#                                       #            AWS owned key (switching back from true reverts to the AWS owned key). Default: false
#   kms_key_arn: ""                     # (Optional) ARN of an existing symmetric KMS key in the management account and instance region.
#                                       #            Its key policy must follow the Identity Center baseline policy. Empty = the module
#                                       #            creates the key (alias/identity-store-<system_name>). Default: ""
#   deletion_window_in_days: 30         # (Optional) Module-created key only. Waiting period before deletion, 7-30. Default: 30
#   multi_region: false                 # (Optional) Module-created key only. true = multi-Region primary key. Default: false
#   enable_key_rotation: true           # (Optional) Module-created key only. Automatic key material rotation. Default: true
#   rotation_period_in_days: 90         # (Optional) Module-created key only. Rotation period, 90-2560. Default: 90
#   delegated_admin_account_ids: []     # (Optional) Module-created key only. Identity Center delegated administrator account IDs
#                                       #            granted key administration (kms:*) in the key policy; list the account
#                                       #            of every spoke deployment (is_hub: false) of this module. Default: []
variable "encryption" {
  description = "(Optional) At-rest encryption of the IAM Identity Center instance with a customer managed KMS key, applied only when is_hub is true. Default: {} (AWS owned key)"
  type        = any
  default     = {}
  validation {
    condition     = try(var.encryption.enabled, null) == null || can(tobool(var.encryption.enabled))
    error_message = "encryption.enabled must be true or false."
  }
  validation {
    condition     = try(coalesce(var.encryption.kms_key_arn), "") == "" || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/", var.encryption.kms_key_arn))
    error_message = "encryption.kms_key_arn must be a KMS key ARN (arn:<partition>:kms:<region>:<account-id>:key/<key-id>), not an alias or a bare key ID."
  }
}
