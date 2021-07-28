#!/bin/env bash
docker build -t local-krakend:latest .
kind load docker-image local-krakend:latest
kubectl rollout restart deployment krakend-deployment