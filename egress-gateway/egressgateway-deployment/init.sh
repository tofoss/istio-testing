#!/usr/bin/zsh

istioctl manifest generate \
    --filename egressgateway-operator.yaml \
    --cluster-specific > egressgateway.yaml

echo "Run kubectl apply -f egressgateway.yaml to apply the gateway deployment"
