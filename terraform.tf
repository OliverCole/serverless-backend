data "aws_caller_identity" "current" {}

variable "environment_configs" {
  type = "map"
}

variable "region" {
  default = "eu-west-1"
}

provider "aws" {
  region = "${var.region}"
}

variable "mailgun_smtp_password" {}

provider "mailgun" {
  api_key = "${var.environment_configs["mail_api_key"]}"
}

resource "mailgun_domain" "serverless" {
  name          = "${var.environment_configs["mailgun_domain_name"]}"
  spam_action   = "disabled"
  smtp_password = "${var.mailgun_smtp_password}"
}

output "send" {
  value = "${mailgun_domain.serverless.sending_records}"
}

output "receive" {
  value = "${mailgun_domain.serverless.receiving_records}"
}

resource "aws_dynamodb_table" "emails" {
  name           = "emails"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "email"

  attribute {
    name = "email"
    type = "S"
  }
}

resource "aws_iam_role" "LambdaBackend_master_lambda" {
  name = "LambdaBackend_master_lambda"
  path = "/"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "LambdaBackend_master_lambda_AmazonDynamoDBFullAccess" {
  role       = "${aws_iam_role.LambdaBackend_master_lambda.name}"
  policy_arn = "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
}

resource "aws_iam_role_policy_attachment" "LambdaBackend_master_lambda_CloudWatchFullAccess" {
  role       = "${aws_iam_role.LambdaBackend_master_lambda.name}"
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchFullAccess"
}

resource "aws_iam_role_policy" "ssm_read" {
  name = "ssm_read"
  role = "${aws_iam_role.LambdaBackend_master_lambda.id}"

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
          "ssm:DescribeParameters"
      ],
      "Resource": "*"
    },
    {
        "Effect": "Allow",
        "Action": [
            "ssm:GetParameters"
        ],
        "Resource": "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter/${terraform.env}/*"
    }
  ]
}
POLICY
}

resource "aws_kms_key" "LambdaBackend_config" {
  description             = "LambdaBackend_config_key"
  deletion_window_in_days = 7

  policy = <<POLICY
{
  "Version" : "2012-10-17",
  "Id" : "key-consolepolicy-3",
  "Statement" : [ {
    "Sid" : "Enable IAM User Permissions",
    "Effect" : "Allow",
    "Principal" : {
      "AWS" : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
    },
    "Action" : "kms:*",
    "Resource" : "*"
  }, {
    "Sid" : "Allow use of the key",
    "Effect" : "Allow",
    "Principal" : {
      "AWS" : "${aws_iam_role.LambdaBackend_master_lambda.arn}"
    },
    "Action" : [ "kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey" ],
    "Resource" : "*"
  }, {
    "Sid" : "Allow attachment of persistent resources",
    "Effect" : "Allow",
    "Principal" : {
      "AWS" : "${aws_iam_role.LambdaBackend_master_lambda.arn}"
    },
    "Action" : [ "kms:CreateGrant", "kms:ListGrants", "kms:RevokeGrant" ],
    "Resource" : "*",
    "Condition" : {
      "Bool" : {
        "kms:GrantIsForAWSResource" : "true"
      }
    }
  } ]
}
POLICY
}

resource "aws_kms_alias" "LambdaBackend_config_alias" {
  name          = "alias/LambdaBackend_config"
  target_key_id = "${aws_kms_key.LambdaBackend_config.key_id}"
}

module "parameters" {
  source     = "/ssm_parameter_map"
  configs    = "${var.environment_configs}"
  prefix     = "${terraform.env}"
  kms_key_id = "${aws_kms_key.LambdaBackend_config.key_id}"
}

resource "aws_lambda_function" "LambdaBackend_lambda" {
  filename         = "email_lambda.zip"
  function_name    = "LambdaBackend"
  role             = "${aws_iam_role.LambdaBackend_master_lambda.arn}"
  handler          = "index.handler"
  source_code_hash = "${base64sha256(file("email_lambda.zip"))}"
  runtime          = "nodejs6.10"
  timeout          = 15
  publish          = true

  environment {
    variables = {
      env = "${terraform.env}"
    }
  }
}

resource "aws_api_gateway_account" "gateway" {
  cloudwatch_role_arn = "${aws_iam_role.cloudwatchlog.arn}"
}

resource "aws_iam_role" "cloudwatchlog" {
  name = "cloudwatchlog"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "apigateway.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_policy_attachment" "cloudwatchlog" {
  name       = "cloudwatchlog"
  roles      = ["${aws_iam_role.cloudwatchlog.name}"]
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_rest_api" "service" {
  name = "BackendService"
}

resource "aws_api_gateway_resource" "api" {
  rest_api_id = "${aws_api_gateway_rest_api.service.id}"
  parent_id   = "${aws_api_gateway_rest_api.service.root_resource_id}"
  path_part   = "api"
}

resource "aws_api_gateway_resource" "email" {
  rest_api_id = "${aws_api_gateway_rest_api.service.id}"
  parent_id   = "${aws_api_gateway_resource.api.id}"
  path_part   = "email"
}

resource "aws_api_gateway_method" "post" {
  rest_api_id   = "${aws_api_gateway_rest_api.service.id}"
  resource_id   = "${aws_api_gateway_resource.email.id}"
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "integration" {
  rest_api_id             = "${aws_api_gateway_rest_api.service.id}"
  resource_id             = "${aws_api_gateway_resource.email.id}"
  http_method             = "${aws_api_gateway_method.post.http_method}"
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${var.region}:lambda:path/2015-03-31/functions/${aws_lambda_function.LambdaBackend_lambda.arn}:$${stageVariables.alias}/invocations"
  passthrough_behavior    = "WHEN_NO_TEMPLATES"

  request_templates {
    "application/x-www-form-urlencoded" = <<EOF
##  See http://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-mapping-template-reference.html
##  This template will pass through all parameters including path, querystring, header, stage variables, and context through to the integration endpoint via the body/payload
#set($allParams = $input.params())
{
"body-json" : $input.json('$'),
"params" : {
#foreach($type in $allParams.keySet())
    #set($params = $allParams.get($type))
"$type" : {
    #foreach($paramName in $params.keySet())
    "$paramName" : "$util.escapeJavaScript($params.get($paramName))"
        #if($foreach.hasNext),#end
    #end
}
    #if($foreach.hasNext),#end
#end
},
"stage-variables" : {
#foreach($key in $stageVariables.keySet())
"$key" : "$util.escapeJavaScript($stageVariables.get($key))"
    #if($foreach.hasNext),#end
#end
},
"context" : {
    "account-id" : "$context.identity.accountId",
    "api-id" : "$context.apiId",
    "api-key" : "$context.identity.apiKey",
    "authorizer-principal-id" : "$context.authorizer.principalId",
    "caller" : "$context.identity.caller",
    "cognito-authentication-provider" : "$context.identity.cognitoAuthenticationProvider",
    "cognito-authentication-type" : "$context.identity.cognitoAuthenticationType",
    "cognito-identity-id" : "$context.identity.cognitoIdentityId",
    "cognito-identity-pool-id" : "$context.identity.cognitoIdentityPoolId",
    "http-method" : "$context.httpMethod",
    "stage" : "$context.stage",
    "source-ip" : "$context.identity.sourceIp",
    "user" : "$context.identity.user",
    "user-agent" : "$context.identity.userAgent",
    "user-arn" : "$context.identity.userArn",
    "request-id" : "$context.requestId",
    "resource-id" : "$context.resourceId",
    "resource-path" : "$context.resourcePath"
    }
}

EOF
  }
}

resource "aws_api_gateway_method_response" "301" {
  rest_api_id = "${aws_api_gateway_rest_api.service.id}"
  resource_id = "${aws_api_gateway_resource.email.id}"
  http_method = "${aws_api_gateway_method.post.http_method}"
  status_code = "301"
  depends_on  = ["aws_api_gateway_integration.integration"]

  response_parameters = {
    "method.response.header.Location" = true
  }
}

resource "aws_api_gateway_integration_response" "default" {
  rest_api_id       = "${aws_api_gateway_rest_api.service.id}"
  resource_id       = "${aws_api_gateway_resource.email.id}"
  http_method       = "${aws_api_gateway_method.post.http_method}"
  status_code       = "${aws_api_gateway_method_response.301.status_code}"
  selection_pattern = "^Email.MovedPermanently.*"

  response_parameters = {
    "method.response.header.Location" = "integration.response.body.errorType"
  }

  depends_on = ["aws_api_gateway_integration.integration"]
}

resource "aws_api_gateway_deployment" "deploy" {
  depends_on = ["aws_api_gateway_method.post", "aws_api_gateway_integration.integration", "aws_api_gateway_integration_response.default"]

  rest_api_id = "${aws_api_gateway_rest_api.service.id}"
  stage_name  = "${terraform.env}"

  variables = {
    "alias" = "${terraform.env}"
  }
}

resource "aws_api_gateway_method_settings" "settings" {
  rest_api_id = "${aws_api_gateway_rest_api.service.id}"
  stage_name  = "${aws_api_gateway_deployment.deploy.stage_name}"
  method_path = "${aws_api_gateway_resource.api.path_part}/${aws_api_gateway_resource.email.path_part}/${aws_api_gateway_method.post.http_method}"

  settings {
    metrics_enabled = true
    logging_level   = "INFO"
  }
}

resource "aws_lambda_alias" "alias" {
  name             = "${terraform.env}"
  function_name    = "${aws_lambda_function.LambdaBackend_lambda.arn}"
  function_version = "$LATEST"
}

resource "aws_lambda_permission" "invoke" {
  statement_id  = "${terraform.env}Invoke"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.LambdaBackend_lambda.arn}"
  principal     = "apigateway.amazonaws.com"
  source_arn    = "arn:aws:execute-api:${var.region}:${data.aws_caller_identity.current.account_id}:${aws_api_gateway_rest_api.service.id}/*/${aws_api_gateway_method.post.http_method}/${aws_api_gateway_resource.api.path_part}/${aws_api_gateway_resource.email.path_part}"
  qualifier     = "${terraform.env}"
  depends_on    = ["aws_lambda_alias.alias"]
}

output "invoke_url" {
  value = "${aws_api_gateway_deployment.deploy.invoke_url}/${aws_api_gateway_resource.api.path_part}/${aws_api_gateway_resource.email.path_part}"
}
