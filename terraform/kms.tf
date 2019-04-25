data "template_file" "kms-policy" {
  template = "${file("${path.module}/policies/kms-resource-policy.json.tmpl")}"

  vars {
    accountid = "${data.aws_caller_identity.current.account_id}"
  }
}

resource "aws_kms_key" "propagationkey" {
  description             = "propagation${local.branch_suffix}"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  lifecycle {
    prevent_destroy = false
  }

  policy = "${data.template_file.kms-policy.rendered}"
}

resource "aws_kms_alias" "propagationkey" {
  name          = "alias/propagation${local.branch_suffix}"
  target_key_id = "${aws_kms_key.propagationkey.key_id}"
}
