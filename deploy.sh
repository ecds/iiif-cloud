#!/bin/bash
echo "Running deploy script"

echo "Logging in to AWS"
aws ecr get-login-password --region us-east-1 |
  docker login --username AWS --password-stdin 310867200447.dkr.ecr.us-east-1.amazonaws.com
echo "Logged in successfully"
echo "$PROD_ENV" >> .env

echo "Building and tagging Docker image"
docker build -t iiif-cloud --no-cache .
docker tag iiif-cloud 310867200447.dkr.ecr.us-east-1.amazonaws.com/iiif-cloud:latest

echo "Pushing image"
docker push 310867200447.dkr.ecr.us-east-1.amazonaws.com/iiif-cloud:latest

echo "Updating service"
aws ecs update-service --cluster iiif-cloud --service iiif-cloud --force-new-deployment --region us-east-1
