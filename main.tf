##
# (c) 2024 - Cloud Ops Works LLC - https://cloudops.works/
#            On GitHub: https://github.com/cloudopsworks
#            Distributed Under Apache v2.0 License
#

data "aws_ssoadmin_instances" "sso" {}

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
