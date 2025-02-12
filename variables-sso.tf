##
# (c) 2024 - Cloud Ops Works LLC - https://cloudops.works/
#            On GitHub: https://github.com/cloudopsworks
#            Distributed Under Apache v2.0 License
#

## YAML Format
# users:
#  - user_name: "user@example.com"
#    first_name: firstname
#    last_name: lastname
#    emails:
#      - email: user@example.com
#        primary: true
#        type: work
#    groups:
#      - "Group1"
#      - "Group2"
variable "users" {
  description = "List of users to create in the identity store"
  type        = any
  default     = []
}
## YAML Format
# groups:
#   - display_name: "Admins"
#     description: "Admins group"
variable "groups" {
  description = "List of groups to create in the identity store"
  type        = any
  default     = []
}