data "aws_caller_identity" "current" {}

locals {
  name_prefix = lower("${split("/", "${data.aws_caller_identity.current.arn}")[1]}-httpapi")
}

resource "aws_dynamodb_table" "table" {
  name         = "${local.name_prefix}-ddb"
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
// Lambda setup
#========================================================================

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/src.zip"
}

// Define lambda function
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

resource "aws_iam_role" "lambda_exec" {
  name = "${local.name_prefix}-LambdaDdbPostRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Sid    = ""
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "lambda_exec_role" {
  name = "${local.name_prefix}-LambdaDdbPostPolicy"

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

resource "aws_iam_role_policy_attachment" "lambda_policy" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_exec_role.arn
}

#========================================================================
// API Gateway section
#========================================================================

resource "aws_apigatewayv2_api" "http_api" {
  name          = local.name_prefix
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id = aws_apigatewayv2_api.http_api.id

  name        = "$default"
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

resource "aws_apigatewayv2_integration" "apigw_lambda" {
  api_id = aws_apigatewayv2_api.http_api.id

  integration_uri    = aws_lambda_function.http_api_lambda.invoke_arn
  integration_type   = "AWS_PROXY"
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "post" {
  api_id = aws_apigatewayv2_api.http_api.id

  route_key = "POST /movies"
  target    = "integrations/${aws_apigatewayv2_integration.apigw_lambda.id}"
}

resource "aws_cloudwatch_log_group" "api_access_logs" {
  name = "/aws/api_gw/${aws_apigatewayv2_api.http_api.name}"

  retention_in_days = 7
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.http_api_lambda.function_name
  principal     = "apigateway.amazonaws.com"

  source_arn = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

#========================================================================
// Custom domain for API Gateway section
#========================================================================

# Fetch the Route 53 hosted zone information for your domain
data "aws_route53_zone" "zone" {
  name = "sctp-sandbox.com"
}

# ACM (AWS Certificate Manager) module for managing SSL certificates
module "acm" {
  source  = "terraform-aws-modules/acm/aws"
  version = "~> 4.0"

  domain_name       = lower("${local.name_prefix}.sctp-sandbox.com") # Full domain name
  zone_id           = data.aws_route53_zone.zone.zone_id      # Route 53 hosted zone ID
  validation_method = "DNS"                                   # Validation through Route 53 DNS records
}

# Define the custom domain for API Gateway (HTTP API)
resource "aws_apigatewayv2_domain_name" "http_api" {
  domain_name = lower("${local.name_prefix}.sctp-sandbox.com") # Your custom domain name

  domain_name_configuration {
    certificate_arn = module.acm.acm_certificate_arn # ACM certificate ARN
    endpoint_type   = "REGIONAL"                     # API Gateway supports REGIONAL or EDGE endpoints
    security_policy = "TLS_1_2"                      # TLS security policy
  }
}

# Map the custom domain to an API Gateway stage
resource "aws_apigatewayv2_api_mapping" "example" {
  api_id      = aws_apigatewayv2_api.http_api.id                  # API ID
  domain_name = aws_apigatewayv2_domain_name.http_api.domain_name # Custom domain name
  stage       = aws_apigatewayv2_stage.default.name               # API Gateway stage name
}

# Create a DNS record in Route 53 to map the custom domain to the API Gateway domain
resource "aws_route53_record" "http_api" {
  zone_id = data.aws_route53_zone.zone.zone_id                # Route 53 hosted zone ID
  name    = lower(aws_apigatewayv2_domain_name.http_api.domain_name) # Domain name (custom domain)
  type    = "A"                                               # A record for aliasing the domain

  alias {
    name                   = aws_apigatewayv2_domain_name.http_api.domain_name_configuration[0].target_domain_name # Target domain name (API Gateway)
    zone_id                = aws_apigatewayv2_domain_name.http_api.domain_name_configuration[0].hosted_zone_id     # Hosted zone ID
    evaluate_target_health = false                                                                                 # Optional: Route 53 health check (false by default)
  }
}
