Resources:
  ApiGatewayRestApi:
    Type: AWS::ApiGateway::RestApi
    Properties:
      Name: MyApiGateway
      EndpointConfiguration:
        Types:
          - REGIONAL

  ApiGatewayResource:
    Type: AWS::ApiGateway::Resource
    Properties:
      RestApiId: !Ref ApiGatewayRestApi
      ParentId: !GetAtt ApiGatewayRestApi.RootResourceId
      PathPart: mytestresource

  ApiGatewayMethod:
    Type: AWS::ApiGateway::Method
    Properties:
      RestApiId: !Ref ApiGatewayRestApi
      ResourceId: !Ref ApiGatewayResource
      HttpMethod: GET
      AuthorizationType: NONE
      Integration:
        Type: AWS_PROXY
        IntegrationHttpMethod: GET
        Uri: !Sub
          - arn:aws:apigateway:${AWS::Region}:lambda:path/2015-03-31/functions/${LambdaFunction.Arn}/invocations
          - lambdaArn: !GetAtt LambdaFunction.Arn
      MethodResponses:
            - StatusCode: 200
              ResponseModels:
                application/json: "Empty"

  Deployment:
    Type: AWS::ApiGateway::Deployment
    DependsOn: ApiGatewayMethod
    Properties:
      RestApiId: !Ref ApiGatewayRestApi
      StageName: Prod

  LambdaFunction:
    Type: AWS::Lambda::Function
    Properties:
      FunctionName: MytestFunction
      Code:
        ZipFile: |
          import json
          import boto3

          def lambda_handler(event, context):
              path = event['queryStringParameters']['path']

              if path == '/nginx':
                  path = 'my-ecs-task'
                  response = {
                      'statusCode': 200,
                      'headers': {'Content-Type': 'application/json'},
                      'body': json.dumps('/nginx')
                  }
                  
                  # Create a Boto3 client for ECS
                  ecs_client = boto3.client('ecs')
                  
                  # Find the task definition ARN for "nginx"
                  response = ecs_client.list_task_definitions(familyPrefix=path, status='ACTIVE')
                  
                  if 'taskDefinitionArns' in response:
                      # Get the ARN of the latest task definition
                      task_definition_arn = response['taskDefinitionArns'][0]
                      
                      # Run the task using the task definition ARN
                      response = ecs_client.run_task(
                          cluster='my-test-cluster',  # Replace with your ECS cluster name
                          taskDefinition=task_definition_arn,
                          launchType='FARGATE',  # Or 'EC2' if using EC2 launch type
                          networkConfiguration={
                              'awsvpcConfiguration': {
                                  'subnets': ['subnet-004ba0e8583ea08c2'],  # Replace with your subnet ID(s)
                                  'securityGroups': ['sg-09071bc7ff4ffb58e'],  # Replace with your security group ID(s)
                                  'assignPublicIp': 'ENABLED'  # Set to 'DISABLED' if using private subnets
                              }
                          }
                      )
                      
                      # Return the task ARN if successful
                      task_arn = response['tasks'][0]['taskArn']
                      response = {
                          'statusCode': 200,
                          'headers': {'Content-Type': 'application/json'},
                          'body': json.dumps({'path': path, 'taskArn': task_arn})
                      }
                  else:
                      response = {
                          'statusCode': 404,
                          'headers': {'Content-Type': 'application/json'},
                          'body': json.dumps('Task definition not found')
                      }
              else:
                  response = {
                      'statusCode': 404,
                      'headers': {'Content-Type': 'application/json'},
                      'body': json.dumps('Path not found')
                  }

              return response

      Handler: index.lambda_handler
      Role: !GetAtt LambdaIAMRole.Arn
      Runtime: python3.10  

  LambdaIAMRole:
    Type: AWS::IAM::Role
    Properties:
      AssumeRolePolicyDocument:
        Version: 2012-10-17
        Statement:
          - Action:
              - sts:AssumeRole
            Effect: Allow
            Principal:
              Service:
                - lambda.amazonaws.com
      Policies:
        - PolicyDocument:
            Version: 2012-10-17
            Statement:
              - Effect: Allow
                Action: ecs:*
                Resource: "*"
              - Action:
                  - logs:CreateLogGroup
                  - logs:CreateLogStream
                  - logs:PutLogEvents
                Effect: Allow
                Resource:
                  - !Sub arn:aws:logs:${AWS::Region}:${AWS::AccountId}:log-group:/aws/lambda/MytestFunction:*
              - Effect: Allow
                Action: iam:PassRole
                Resource: "arn:aws:iam::193014247688:role/ecsTaskExecutionRole"
          PolicyName: lambda

  LambdaLogGroup:
    Type: AWS::Logs::LogGroup
    Properties:
      LogGroupName: !Sub /aws/lambda/MytestFunction
      RetentionInDays: 90

  LambdaPermission:
    Type: AWS::Lambda::Permission
    Properties:
      FunctionName: !GetAtt LambdaFunction.Arn
      Action: lambda:InvokeFunction
      Principal: apigateway.amazonaws.com
      SourceArn: !Sub "arn:aws:execute-api:${AWS::Region}:${AWS::AccountId}:${ApiGatewayRestApi}/*/GET/mytestresource"
