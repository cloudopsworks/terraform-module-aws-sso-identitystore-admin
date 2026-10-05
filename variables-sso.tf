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
