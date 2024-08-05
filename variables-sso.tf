##
# (c) 2024 - Cloud Ops Works LLC - https://cloudops.works/
#            On GitHub: https://github.com/cloudopsworks
#            Distributed Under Apache v2.0 License
#

variable "users" {
  description = "List of users to create in the identity store"
  type        = any
  default     = []
}

variable "groups" {
  description = "List of groups to create in the identity store"
  type        = any
  default     = []
}