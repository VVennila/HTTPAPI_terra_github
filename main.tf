# Fetch caller identity for naming
data "aws_caller_identity" "current" {}

# Local variables for naming convention
locals {
  name_prefix = lower("${split("/", "${data.aws_caller_identity.current.arn}")[1]}-httpapi")
}

# DynamoDB Table
resource "aws_dynamodb_table" "table" {
  name         = "${local.name_prefix}-ddb-new"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "year"
  range_key    = "title"

  attribute {
    name = "year"
    type = "N"
  }

  attribute {
    name = "title"
    type = "S"
  }
}

#========================================================================
# Lambda setup
#========================================================================

# Package the Lambda function code into a zip file
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/src.zip"
}

# Define Lambda function
resource "aws_lambda_function" "http_api_lambda" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${local.name_prefix}-lambda"
  description      = "Lambda function to write to DynamoDB"
  runtime          = "python3.8"
  handler          = "app.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  role             = aws_iam_role.lambda_exec.arn

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      DDB_TABLE = aws_dynamodb_table.table.name
    }
  }
}

# IAM Role for Lambda
resource "aws_iam_role" "lambda_exec" {
  name = "${local.name_prefix}-LambdaDdbPostRole-new"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Sid       = ""
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

# IAM Policy for Lambda
resource "aws_iam_policy" "lambda_exec_role" {
  name = "${local.name_prefix}-LambdaDdbPostPolicy-new"  # Ensure unique name

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "dynamodb:GetItem",
                "dynamodb:PutItem",
                "dynamodb:UpdateItem"
            ],
            "Resource": "${aws_dynamodb_table.table.arn}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "logs:CreateLogGroup",
                "logs:CreateLogStream",
                "logs:PutLogEvents"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": [
                "xray:PutTraceSegments",
                "xray:PutTelemetryRecords"
            ],
            "Resource": "*"
        }
    ]
}
POLICY
}

# Attach the policy to the IAM role
resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_exec_role.arn
}

#========================================================================
# API Gateway section
#========================================================================

# Define the HTTP API
resource "aws_apigatewayv2_api" "http_api" {
  name          = local.name_prefix
  protocol_type = "HTTP"
}

# Define the API stage
resource "aws_apigatewayv2_stage" "default" {
  api_id     = aws_apigatewayv2_api.http_api.id
  name       = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access_logs.arn

    format = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      protocol                = "$context.protocol"
      httpMethod              = "$context.httpMethod"
      resourcePath            = "$context.resourcePath"
      routeKey                = "$context.routeKey"
      status                  = "$context.status"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }

  depends_on = [aws_cloudwatch_log_group.api_access_logs]
}

# Lambda integration with API Gateway
resource "aws_apigatewayv2_integration" "apigw_lambda" {
  api_id             = aws_apigatewayv2_api.http_api.id
  integration_uri    = aws_lambda_function.http_api_lambda.invoke_arn
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
}

# Define API route
resource "aws_apigatewayv2_route" "post" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /movies"
  target    = "integrations/${aws_apigatewayv2_integration.apigw_lambda.id}"
}

# CloudWatch Log Group for API Gateway access logs
resource "aws_cloudwatch_log_group" "api_access_logs" {
  name              = "/aws/api_gw/${aws_apigatewayv2_api.http_api.name}"
  retention_in_days = 7
}

# Lambda permission for API Gateway
resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.http_api_lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

#========================================================================
# Custom domain for API Gateway section
#========================================================================

# Fetch the Route 53 hosted zone information for your domain
data "aws_route53_zone" "zone" {
  name = "sctp-sandbox.com"
}

# ACM (AWS Certificate Manager) module for managing SSL certificates
module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 4.0"

  domain_name      = "vennila-httpapi-api.sctp-sandbox.com"  # Exact domain name for API Gateway
  zone_id          = data.aws_route53_zone.zone.zone_id
  validation_method = "DNS"
}

# Define the custom domain for API Gateway (HTTP API)
resource "aws_apigatewayv2_domain_name" "http_api" {
  domain_name = "vennila-httpapi-api.sctp-sandbox.com"

  domain_name_configuration {
    certificate_arn = module.acm.acm_certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

# Map the custom domain to an API Gateway stage
resource "aws_apigatewayv2_api_mapping" "example" {
  api_id      = aws_apigatewayv2_api.http_api.id
  domain_name = aws_apigatewayv2_domain_name.http_api.id
  stage       = aws_apigatewayv2_stage.default.id
}

# Create a DNS record in Route 53 to map the custom domain to the API Gateway domain
resource "aws_route53_record" "http_api" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = aws_apigatewayv2_domain_name.http_api.domain_name
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.http_api.domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.http_api.domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}
