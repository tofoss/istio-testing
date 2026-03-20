# istio testing

## Egress control with `ServiceEntry`

### 1. Create namespaces managed by ASM:
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: istio-egress
  labels:
    name: istio-egress
    istio-injection: disabled
---
apiVersion: v1
kind: Namespace
metadata:
  name: istio-test
  labels:
    istio.io/rev: asm-managed
```
### 2. Create Pod
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: python-test-pod
  namespace: istio-test
spec:
  containers:
    - name: python
      image: python:latest
      command: ["python"]
      args: ["-c", "import time; print('hello from python'); time.sleep(3600)"]
  restartPolicy: Never
```

```shell
k exec -it python-test-pod -- curl example.com -v
```
All egress traffic should be allowed by default.
  
### 3. Apply `REGISTRY_ONLY` by configuring the sidecar
```yaml
apiVersion: networking.istio.io/v1beta1
kind: Sidecar
metadata:
  name: default
  namespace: istio-test
spec:
  outboundTrafficPolicy:
    mode: REGISTRY_ONLY
```
Result:
- Egress to *.clusterset.local is denied.
- Egress directly to service ips in second cluster is OK.
- Egress to *.cluster.local is OK.
- Egress to example.com and direct ip is denied.

### 4. Add a `ServiceEntry` of clusterset addresses
```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: clusterset.local
spec:
  hosts:
  - "dataplane-nginx-controller.union.svc.clusterset.local"
  ports:
  - number: 80
    name: http
    protocol: HTTP
  - number: 443
    name: https
    protocol: HTTPS
  resolution: DNS
```

```shell
k exec -it python-test-pod -- curl dataplane-nginx-controller.union.svc.clusterset.local -v
```
Now returns a good response.

The istio sidecar is controlling the egress traffic on its own, no gateway is configured yet.

### 5. Add a `ServiceEntry` for www.google.com
```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: google
spec:
  hosts:
  - www.google.com
  ports:
  - number: 443
    name: https
    protocol: HTTPS
  resolution: DNS
  location: MESH_EXTERNAL
```
`curl https://google.com` does not respond ok, but `curl https://www.google.com` does.

Changing the hosts to the following reverses the outcome:
```yaml
  hosts:
  - google.com
```

In short, the hosts you add to a `ServiceEntry` needs to be very specific.

## TLS Origination in sidecar

 To enable TLS origination in the sidecar we can add a `targetPort` to a service entry and use a `DestinationRule` to perform the TLS origination.

 ```yaml
 apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: edition-cnn-com
spec:
  hosts:
  - edition.cnn.com
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
    targetPort: 443
  resolution: DNS
---
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: edition-cnn-com
spec:
  host: edition.cnn.com
  trafficPolicy:
    portLevelSettings:
    - port:
        number: 80
      tls:
        mode: SIMPLE # initiates HTTPS when accessing edition.cnn.com
 ```

With this in place the workload can call `curl http://edition.cnn.com` and the proxy will upgrade the request to TLS when accessing the remote edition.cnn.com.

### L7 Egress traffic controls

TLS origination allows us inspect the HTTP traffic and control the routing to external hosts with a `VirtualService`

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: edition-cnn-com
  namespace: istio-test
spec:
  hosts:
  - edition.cnn.com
  http:
  - match:
    - uri:
        exact: /world
    - uri:
        prefix: /world/
    route:
    - destination:
        host: edition.cnn.com
        port:
          number: 80
  - directResponse:
      status: 403
```

This service routes traffic to `edition.cnn.com/world` and `edition.cnn.com/world/*` and responds with 403 for any other path.

## Egress Gateway
To install an egress gateway on GKE with managed istio we have to jump a few hoops.

We need a `IstioOperator` CRD, but GKE does not have the CRD installed so we only use it to genererate the manifests to configure the gateway deployment.

```yaml
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  name: egressgateway-operator
  annotations:
    config.kubernetes.io/local-config: "true"
spec:
  profile: empty
  revision: asm-managed
  components:
    egressGateways:
    - name: istio-egressgateway
      namespace: istio-egress
      enabled: true
  values:
    gateways:
      istio-egressgateway:
        injectionTemplate: gateway
```

Then we run:
```yaml
istioctl manifest generate \
    --filename egressgateway-operator.yaml \
    --cluster-specific > egressgateway.yaml
```

`egressgateway.yaml` contains all the manifests required for the actual deployment, so just apply it `kubectl apply -f egressgateway.yaml`.

We can then configure the gateway with:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: istio-egressgateway
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - edition.cnn.com
```

Add a `ServiceEntry`:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: ServiceEntry
metadata:
  name: cnn
spec:
  hosts:
  - edition.cnn.com
  ports:
  - number: 80
    name: http-port
    protocol: HTTP
  - number: 443
    name: https
    protocol: HTTPS
  resolution: DNS
```

A `VirtualSerivce` that routes traffic to the gateway:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: direct-cnn-through-egress-gateway
spec:
  hosts:
  - edition.cnn.com
  gateways:
  - istio-egressgateway
  - mesh
  http:
  - match:
    - gateways:
      - mesh
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-egress.svc.cluster.local
        port:
          number: 80
      weight: 100
  - match:
    - gateways:
      - istio-egressgateway
      port: 80
    route:
    - destination:
        host: edition.cnn.com
        port:
          number: 80
      weight: 100
```
### TLS Origination in Gateway

Modify the gatweay to use HTTPS:
```yaml
apiVersion: networking.istio.io/v1beta1
kind: Gateway
metadata:
  name: istio-egressgateway
  namespace: istio-egress
spec:
  selector:
    istio: egressgateway
  servers:
  - port:
      number: 80
      name: https-port-for-tls-origination
      protocol: HTTPS
    hosts:
    - edition.cnn.com
    tls:
      mode: ISTIO_MUTUAL
```

The outgoing destination in the `VirtualService` also needs to be https:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: direct-cnn-through-egress-gateway
spec:
  hosts:
  - edition.cnn.com
  gateways:
  - istio-egressgateway
  - mesh
  http:
  - match:
    - gateways:
      - mesh
      port: 80
    route:
    - destination:
        host: istio-egressgateway.istio-egress.svc.cluster.local
        subset: cnn
        port:
          number: 80
      weight: 100
  - match:
    - gateways:
      - istio-egressgateway
      port: 80
    route:
    - destination:
        host: edition.cnn.com
        port:
          number: 443
      weight: 100
```

A `DestinationRule` to upgrade the pod -> gateway communication to mTLS (optional):
```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: egressgateway-for-cnn
spec:
  host: istio-egressgateway.istio-egress.svc.cluster.local
  subsets:
  - name: cnn
    trafficPolicy:
      loadBalancer:
        simple: ROUND_ROBIN
      portLevelSettings:
      - port:
          number: 80
        tls:
          mode: ISTIO_MUTUAL
          sni: edition.cnn.com
```

And a `DestinationRule` to originate the TLS, like in the sidecar example.
```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: originate-tls-for-edition-cnn-com
spec:
  host: edition.cnn.com
  trafficPolicy:
    loadBalancer:
      simple: ROUND_ROBIN
    portLevelSettings:
    - port:
        number: 443
      tls:
        mode: SIMPLE # initiates HTTPS for connections to edition.cnn.com
```
