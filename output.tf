##
# (c) 2024 - Cloud Ops Works LLC - https://cloudops.works/
#            On GitHub: https://github.com/cloudopsworks
#            Distributed Under Apache v2.0 License
#

output "identity_store_id" {
  value = data.aws_ssoadmin_instances.sso.identity_store_ids[0]
}

output "identity_store_arn" {
  value = data.aws_ssoadmin_instances.sso.arns[0]
}

output "users" {
  value = {
    for u in aws_identitystore_user.user : u.value.user_name => {
      id           = u.value.user_id
      user_name    = u.value.user_name
      display_name = u.value.display_name
    }
  }
}

output "groups" {
  value = {
    for g in aws_identitystore_group.group : g.value.display_name => {
      id           = g.value.group_id
      display_name = g.value.display_name
    }
  }
}