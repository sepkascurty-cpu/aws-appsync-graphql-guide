# =============================================================================
# AWS AppSync GraphQL API — schema-first, Cognito auth, DynamoDB + Lambda
#
# What this builds:
#   * AppSync GraphQL API (Cognito user pools = default auth,
#     API key = additional provider for local development)
#   * DynamoDB "Orders" table (on-demand, point-in-time recovery)
#   * Lambda resolver function for the `recommendations` field
#   * Unit resolvers in JavaScript (APPSYNC_JS runtime) for
#     getOrder / listOrders / createOrder, plus a real-time subscription
#   * CloudWatch logging on the API so broken resolvers are visible
#
# Usage:
#   terraform init && terraform plan && terraform apply
#   terraform destroy   # <-- run this when you are done experimenting
# =============================================================================

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

variable "aws_region" {
  description = "Region for all resources."
  type        = string
  default     = "ap-southeast-1"
}

variable "project" {
  description = "Name prefix for every resource."
  type        = string
  default     = "appsync-shop"
}

provider "aws" {
  region = var.aws_region
}

# -----------------------------------------------------------------------------
# DynamoDB — the Orders table
#
# Partition key = order id. A GSI on userId lets listOrders(userId) run as a
# single Query instead of a full-table Scan (Scans get expensive fast).
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "orders" {
  name         = "${var.project}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  attribute {
    name = "userId"
    type = "S"
  }

  global_secondary_index {
    name            = "by-user"
    hash_key        = "userId"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Project = var.project
  }
}

# -----------------------------------------------------------------------------
# Cognito — sign-up / sign-in for real users.
# AppSync trusts the JWT this pool issues; resolvers can read the caller's
# identity as ctx.identity.claims inside JavaScript resolvers.
# -----------------------------------------------------------------------------
resource "aws_cognito_user_pool" "users" {
  name = "${var.project}-users"

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.project}-web"
  user_pool_id = aws_cognito_user_pool.users.id

  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

# -----------------------------------------------------------------------------
# AppSync GraphQL API
#
# The schema is the contract: frontend and backend agree on it first, then
# resolvers are wired to each field. Changing the schema later is a breaking
# change for old app versions, so design it around how clients read data.
# -----------------------------------------------------------------------------
resource "aws_appsync_graphql_api" "shop" {
  name = "${var.project}-api"

  authentication_type = "AMAZON_COGNITO_USER_POOLS"

  user_pool_config {
    aws_region     = var.aws_region
    user_pool_id   = aws_cognito_user_pool.users.id
    default_action = "ALLOW"
  }

  # API key auth is an ADDITIONAL provider — handy for curl demos and local
  # development. Never use it as the only auth for user data.
  additional_authentication_provider {
    authentication_type = "API_KEY"
  }

  schema = <<-EOT
    type Order {
      id: ID!
      userId: String!
      total: Float!
      status: String!
      createdAt: AWSDateTime!
    }

    type Query {
      getOrder(id: ID!): Order
      listOrders(userId: String!): [Order]
      recommendations(userId: String!): [String]
    }

    type Mutation {
      createOrder(userId: String!, total: Float!): Order
    }

    type Subscription {
      onNewOrder(userId: String!): Order
        @aws_subscribe(mutations: ["createOrder"])
    }
  EOT

  log_config {
    cloudwatch_logs_role_arn = aws_iam_role.appsync_logs.arn
    field_log_level           = "ERROR"
  }

  tags = {
    Project = var.project
  }
}

resource "aws_appsync_api_key" "dev" {
  api_id  = aws_appsync_graphql_api.shop.id
  expires = timeadd(timestamp(), "720h") # 30 days — rotate, don't extend forever
}

# -----------------------------------------------------------------------------
# IAM — AppSync needs permission to touch DynamoDB, invoke Lambda, and write
# logs. One role per concern keeps the blast radius small (least privilege).
# -----------------------------------------------------------------------------
resource "aws_iam_role" "appsync_dynamodb" {
  name = "${var.project}-appsync-dynamodb"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "appsync.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "appsync_dynamodb" {
  name = "${var.project}-appsync-dynamodb"
  role = aws_iam_role.appsync_dynamodb.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:Query",
      ]
      Resource = [
        aws_dynamodb_table.orders.arn,
        "${aws_dynamodb_table.orders.arn}/index/by-user",
      ]
    }]
  })
}

resource "aws_iam_role" "appsync_logs" {
  name = "${var.project}-appsync-logs"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "appsync.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "appsync_logs" {
  role       = aws_iam_role.appsync_logs.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSAppSyncPushToCloudWatchLogs"
}

# -----------------------------------------------------------------------------
# Data sources
# -----------------------------------------------------------------------------
resource "aws_appsync_datasource" "orders_table" {
  api_id           = aws_appsync_graphql_api.shop.id
  name             = "OrdersTable"
  type             = "AMAZON_DYNAMODB"
  service_role_arn = aws_iam_role.appsync_dynamodb.arn

  dynamodb_config {
    table_name = aws_dynamodb_table.orders.name
  }
}

# Lambda data source — for logic that doesn't belong in a table
# (recommendations, validation, calls to third-party services).
data "archive_file" "recommender" {
  type        = "zip"
  output_path = "${path.module}/recommender.zip"

  source {
    filename = "index.py"
    content  = <<-PY
      def handler(event, context):
          """Return three product ids for a user.

          In production this would query a model or a recommendation
          service — here it returns a fixed list so the wiring is
          visible without extra infrastructure.
          """
          user_id = event["arguments"]["userId"]
          return [f"prod-{user_id}-1", f"prod-{user_id}-2", f"prod-{user_id}-3"]
    PY
  }
}

resource "aws_lambda_function" "recommender" {
  filename         = data.archive_file.recommender.output_path
  function_name    = "${var.project}-recommender"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  source_code_hash = data.archive_file.recommender.output_base64sha256
}

resource "aws_iam_role" "lambda_exec" {
  name = "${var.project}-lambda-exec"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_exec" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_appsync_datasource" "recommender_fn" {
  api_id           = aws_appsync_graphql_api.shop.id
  name             = "RecommenderFn"
  type             = "AWS_LAMBDA"
  service_role_arn = aws_iam_role.appsync_lambda.arn

  lambda_config {
    function_arn = aws_lambda_function.recommender.arn
  }
}

resource "aws_iam_role" "appsync_lambda" {
  name = "${var.project}-appsync-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "appsync.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "appsync_lambda" {
  name = "${var.project}-appsync-lambda"
  role = aws_iam_role.appsync_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.recommender.arn
    }]
  })
}

# -----------------------------------------------------------------------------
# Resolvers — JavaScript runtime (APPSYNC_JS). Each resolver has two hooks:
# request() builds the call to the data source, response() shapes the answer.
#
# Rule: never trust the client. createOrder checks that the caller IS the
# user in the arguments (ctx.identity) before writing anything.
# -----------------------------------------------------------------------------
resource "aws_appsync_resolver" "get_order" {
  api_id      = aws_appsync_graphql_api.shop.id
  type        = "Query"
  field       = "getOrder"
  data_source = aws_appsync_datasource.orders_table.name
  kind        = "UNIT"

  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }

  code = <<-JS
    import { util } from '@aws-appsync/utils';

    export function request(ctx) {
      return {
        operation: 'GetItem',
        key: util.dynamodb.toMapValues({ id: ctx.args.id }),
      };
    }

    export function response(ctx) {
      if (ctx.error) util.error(ctx.error.message, ctx.error.type);
      return ctx.result;
    }
  JS
}

resource "aws_appsync_resolver" "list_orders" {
  api_id      = aws_appsync_graphql_api.shop.id
  type        = "Query"
  field       = "listOrders"
  data_source = aws_appsync_datasource.orders_table.name
  kind        = "UNIT"

  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }

  code = <<-JS
    import { util } from '@aws-appsync/utils';

    export function request(ctx) {
      // Query the by-user GSI — one indexed read, never a table Scan.
      return {
        operation: 'Query',
        index: 'by-user',
        query: util.dynamodb.toMapValues({ userId: ctx.args.userId }),
      };
    }

    export function response(ctx) {
      if (ctx.error) util.error(ctx.error.message, ctx.error.type);
      return ctx.result.items;
    }
  JS
}

resource "aws_appsync_resolver" "create_order" {
  api_id      = aws_appsync_graphql_api.shop.id
  type        = "Mutation"
  field       = "createOrder"
  data_source = aws_appsync_datasource.orders_table.name
  kind        = "UNIT"

  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }

  code = <<-JS
    import { util } from '@aws-appsync/utils';

    export function request(ctx) {
      // Ownership check: you can only create orders for yourself.
      const caller = ctx.identity?.claims?.sub;
      if (caller && caller !== ctx.args.userId) {
        util.error('You can only create orders for your own account.', 'Unauthorized');
      }
      return {
        operation: 'PutItem',
        key: util.dynamodb.toMapValues({ id: util.autoId() }),
        attributeValues: util.dynamodb.toMapValues({
          userId: ctx.args.userId,
          total: ctx.args.total,
          status: 'CREATED',
          createdAt: util.time.nowISO8601(),
        }),
      };
    }

    export function response(ctx) {
      if (ctx.error) util.error(ctx.error.message, ctx.error.type);
      return ctx.result;
    }
  JS
}

resource "aws_appsync_resolver" "recommendations" {
  api_id      = aws_appsync_graphql_api.shop.id
  type        = "Query"
  field       = "recommendations"
  data_source = aws_appsync_datasource.recommender_fn.name
  kind        = "UNIT"

  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }

  code = <<-JS
    import { util } from '@aws-appsync/utils';

    export function request(ctx) {
      return {
        operation: 'Invoke',
        payload: { arguments: ctx.args, identity: ctx.identity },
      };
    }

    export function response(ctx) {
      if (ctx.error) util.error(ctx.error.message, ctx.error.type);
      return ctx.result;
    }
  JS
}

# -----------------------------------------------------------------------------
# Outputs — grab these to try the API with curl (see README Quick Start).
# -----------------------------------------------------------------------------
output "graphql_url" {
  description = "The GraphQL endpoint."
  value       = aws_appsync_graphql_api.shop.uris["GRAPHQL"]
}

output "api_key" {
  description = "Dev API key (additional auth provider). Rotate after testing."
  value       = aws_appsync_api_key.dev.key
  sensitive   = true
}

output "user_pool_id" {
  description = "Cognito user pool backing the default auth mode."
  value       = aws_cognito_user_pool.users.id
}
