variable "configs" {
  description = "Key/value pairs to create in the SSM Parameter Store"
  type        = "map"
}

variable "prefix" {
  description = "Prefix to apply to all key names"
}

variable "kms_key_id" {
  description = "ID of KMS key to use to encrypt values"
}

resource "aws_ssm_parameter" "configs" {
  count  = "${length(keys(var.configs))}"
  name   = "/${var.prefix}/${element(keys(var.configs),count.index)}"
  type   = "SecureString"
  value  = "${element(values(var.configs),count.index)}"
  key_id = "${var.kms_key_id}"
}
