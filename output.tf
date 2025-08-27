##
# (c) 2021-2025
#     Cloud Ops Works LLC - https://cloudops.works/
#     Find us on:
#       GitHub: https://github.com/cloudopsworks
#       WebSite: https://cloudops.works
#     Distributed Under Apache v2.0 License
#

output "identity_store_id" {
  value = data.aws_ssoadmin_instances.sso.identity_store_ids[0]
}

output "identity_store_arn" {
  value = data.aws_ssoadmin_instances.sso.arns[0]
}

output "users" {
  value = {
    for u in aws_identitystore_user.user : u.user_name => {
      id           = u.user_id
      user_name    = u.user_name
      display_name = u.display_name
    }
  }
}

output "groups" {
  value = {
    for g in aws_identitystore_group.group : g.display_name => {
      id           = g.group_id
      display_name = g.display_name
    }
  }
}