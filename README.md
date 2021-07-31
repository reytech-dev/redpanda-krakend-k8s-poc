# Use Redpanda with Krakend and metallb in a local k8s cluster

This repository holds instructions about how to setup a local Kubernetes cluster with Kind and run Redpanda and Krakend.
Keep in mind, that this setup is not meant to be used in a production environment! The content of this repository is only tested with Linux Ubuntu 20.04.

The krakend binary in this repository comes with the fix of this issue: 
[https://github.com/luraproject/lura/issues/387](https://github.com/luraproject/lura/issues/387)

Without the fix the included Krakend config will fail sending a response body and return a 500 status code.
You'll get the following error message: 
```text
assignment to entry in nil map
/usr/local/go/src/runtime/map_faststr.go:204 (0xd2ccec)
/go/pkg/mod/github.com/luraproject/lura@v1.4.1/proxy/static.go:31 (0x10f0132)
/go/pkg/mod/github.com/luraproject/lura@v1.4.1/router/gin/endpoint.go:40 (0x191d611)
/go/pkg/mod/github.com/gin-gonic/gin@v1.7.2/context.go:165 (0x1917a79)
/go/pkg/mod/github.com/gin-gonic/gin@v1.7.2/recovery.go:99 (0x1917a60)
/go/pkg/mod/github.com/gin-gonic/gin@v1.7.2/context.go:165 (0x1916b53)
/go/pkg/mod/github.com/gin-gonic/gin@v1.7.2/logger.go:241 (0x1916b12)
/go/pkg/mod/github.com/gin-gonic/gin@v1.7.2/context.go:165 (0x190cd09)
/go/pkg/mod/github.com/gin-gonic/gin@v1.7.2/gin.go:489 (0x190ccef)
/go/pkg/mod/github.com/gin-gonic/gin@v1.7.2/gin.go:445 (0x190c7db)
/usr/local/go/src/net/http/server.go:2887 (0x10b0302)
/usr/local/go/src/net/http/server.go:1952 (0x10ab72c)
/usr/local/go/src/runtime/asm_amd64.s:1371 (0xd88e40)
```

In case you want to build the Krakend binary by yourself, this is the official repository [https://github.com/devopsfaith/krakend-ce](https://github.com/devopsfaith/krakend-ce).

Checkout the respository (with ssh, use the https link if you don't use ssh)
```code
git clone git@github.com:devopsfaith/krakend-ce.git
```

Edit the [Makefile](https://github.com/devopsfaith/krakend-ce/blob/master/Makefile#L50).
```code
sed -i 's;go get github.com/luraproject/lura@v1.4.1;go get github.com/luraproject/lura@master;g' Makefile
```

Build the Krakend binary with docker
```code
docker run --rm -v "${PWD}:/app" -w /app golang:1.16.4 /bin/bash -c 'make update_krakend_deps && make build'
```

The new Krakend binary is available in the project root of the Krakend-CE repository. Just copy it in the root of this repository and replace the existing one.

## Urls

1. [Redpanda](https://vectorized.io/docs/)
2. [Krakend](https://www.krakend.io)
3. [Auth0](https://auth0.com/)

## Requirements

1. [docker](https://www.docker.com/)
2. [Kind](https://kind.sigs.k8s.io/docs/)
3. [helm](https://helm.sh/)

## Prepare Redpanda

Source for [instructions](https://vectorized.io/docs/quick-start-kubernetes)

```bash
# Create kubernetes cluster
kind create cluster
# Install cert-manager
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager --namespace cert-manager --create-namespace --version v1.2.0 --set installCRDs=true

# Install Redpanda operator
helm repo add redpanda https://charts.vectorized.io/
helm repo update
export VERSION=$(curl -s https://api.github.com/repos/vectorizedio/redpanda/releases/latest | jq -r .tag_name)
kubectl apply -k "https://github.com/vectorizedio/redpanda/src/go/k8s/config/crd?ref=${VERSION}"
kubectl wait crd/clusters.redpanda.vectorized.io --for=condition=established --timeout=300s
helm install --namespace redpanda-system --create-namespace redpanda-system --version "${VERSION}" redpanda/redpanda-operator
kubectl wait deployment/redpanda-system-redpanda-operator --for=condition=available --timeout=300s -n redpanda-system
```

## Setup Redpanda cluster
```bash
# Create Redpanda cluster namespace
kubectl create ns chat-with-me
# Setup Redpanda cluster. This will take some time till the cluster is started
kubectl apply -n chat-with-me -f https://raw.githubusercontent.com/vectorizedio/redpanda/dev/src/go/k8s/config/samples/one_node_cluster.yaml
# Wait till cluster is available
kubectl wait pod/one-node-cluster-0 --for=condition=Ready --timeout=300s -n chat-with-me
# Returns cluster information. Should return a single node
kubectl -n chat-with-me run -ti --rm --restart=Never --image "vectorized/redpanda:${VERSION}" -- rpk --brokers one-node-cluster-0.one-node-cluster.chat-with-me.svc.cluster.local:9092 cluster info
# Create topic chat-rooms
kubectl -n chat-with-me run -ti --rm --restart=Never --image "vectorized/redpanda:${VERSION}" -- rpk --brokers one-node-cluster-0.one-node-cluster.chat-with-me.svc.cluster.local:9092 topic create chat-rooms -p 5
```

## Setup metallb LoadBalancer (for local usage)
Source for [instructions](https://kind.sigs.k8s.io/docs/user/loadbalancer)

1. Install metallb
```bash
# Create metallb namespace
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/namespace.yaml
# Create memberlist secrets
kubectl create secret generic -n metallb-system memberlist --from-literal=secretkey="$(openssl rand -base64 128)"
# Apply metallb manifest
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/master/manifests/metallb.yaml
```
3. Receive address pool for LoadBalancer
```bash
# Receive address pool for loadbalancer
docker network inspect -f '{{.IPAM.Config}}' kind
```

4. Create ConfigMap with proper addressRange
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  namespace: metallb-system
  name: config
data:
  config: |
    address-pools:
    - name: default
      protocol: layer2
      addresses:
      - 172.19.255.200-172.19.255.250 # if your address pool returns something like 172.19.0.0/16. Change the value accordingly to the command result.
```

5. Apply ConfigMap
```bash
$ kubectl apply -f metallb-configmap.yaml
```

## Setup Krakend cluster
Source for [instructions](https://www.krakend.io/docs/deploying/kubernetes/)

1. Create krakend.json file with content
```json
{
  "version": 2,
  "timeout": "3000ms",
  "name": "redpanda",
  "endpoints": [
    {
      "endpoint": "/redpanda",
      "method": "POST",
      "output_encoding": "json",
      "extra_config": {
        "github.com/devopsfaith/krakend/proxy": {
            "static": {
                "strategy": "success",
                "data": {
                    "status": 200,
                    "message": "OK"
                }
            }
        }
      },
      "backend": [
        {
          "extra_config": {
            "github.com/devopsfaith/krakend-pubsub/publisher": {
              "topic_url": "chat-rooms"
            }
          },
          "host": ["kafka://"],
          "disable_host_sanitize": true
        }
      ]
    }
  ],
  "port": 8080
}
```

2. Create file "Dockerfile" with content
```bash
FROM devopsfaith/krakend
COPY krakend /usr/bin/krakend # only if you want to use the binary in this repository
COPY krakend.json /etc/krakend/krakend.json
```

3. Build Docker-Image
```bash
$ docker build -t local-krakend:latest .
```

4. Make Docker-Image availabe for kind
```bash
$ kind load docker-image local-krakend:latest
```

5. Create Krakend Kubernetes resources file "krakend-deployment.yaml". We deploy the krakend service as LoadBalancer, so it uses an external ip address
```yaml
---
apiVersion: v1
kind: Service
metadata:
  name: krakend-service
spec:
  type: LoadBalancer
  ports:
  - name: http
    port: 8000
    targetPort: 8080
    protocol: TCP
  selector:
    app: krakend
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: krakend-deployment
spec:
  selector:
    matchLabels:
      app: krakend
  replicas: 2
  template:
    metadata:
      labels:
        app: krakend
    spec:
      containers:
      - name: krakend
        image: local-krakend:latest
        ports:
        - containerPort: 8080
        imagePullPolicy: Never
        command: [ "/usr/bin/krakend" ]
        args: [ "run", "-d", "-c", "/etc/krakend/krakend.json", "-p", "8080" ]
        env:
        - name: KRAKEND_PORT
          value: "8080"
        - name: KAFKA_BROKERS
          value: "one-node-cluster-0.one-node-cluster.chat-with-me.svc.cluster.local:9092"
```

6. Apply "krakend-deployment.yaml" to Kubernetes cluster
```bash
$ kubectl apply -f krakend-deployment.yaml
```

## Add Auth0 integration

1. Create new application in Auth0 ("Regular Webapp")
2. Follow the instructions [here](https://auth0.com/docs/flows/call-your-api-using-resource-owner-password-flow)
3. Replace the above krakend.json config. Replace YOUR-AUDIENCE, YOUR-CLIENT-ID, YOUR-CLIENT-SECRET with the data from your Auth0 application
```json
{
  "version": 2,
  "timeout": "3000ms",
  "name": "redpanda",
  "endpoints": [
    {
      "endpoint": "/redpanda",
      "method": "POST",
      "output_encoding": "json",
      "extra_config": {
        "github.com/devopsfaith/krakend/proxy": {
          "static": {
            "strategy": "success",
            "data": {
              "status": 200,
              "message": "OK"
            }
          }
        }
      },
      "backend": [
        {
          "extra_config": {
            "github.com/devopsfaith/krakend-pubsub/publisher": {
              "topic_url": "chat-rooms"
            }
          },
          "host": ["kafka://"],
          "disable_host_sanitize": true
        }
      ]
    },
    {
      "endpoint": "/login",
      "method": "POST",
      "output_encoding": "no-op",
      "headers_to_pass": [
        "Content-Type"
      ],
      "extra_config": {
        "github.com/devopsfaith/krakend-lua/proxy": {
          "pre": "local r = request.load(); r:body(r:body() .. '&audience=YOUR-AUDIENCE&grant_type=password&client_id=YOUR-CLIENT-ID&client_secret=YOUR-CLIENT-SECRET'); print(r:body());"
        }
      },
      "backend": [
        {
          "encoding": "no-op",
          "url_pattern": "/",
          "host": ["YOUR-TOKEN-ENDPOINT"],
          "disable_host_sanitize": true
        }
      ]
    }
  ],
  "port": 8080
}
```


## Test setup

1. Subscribe to "chat-room" topic
```bash
$ export VERSION=$(curl -s https://api.github.com/repos/vectorizedio/redpanda/releases/latest | jq -r .tag_name)
$ kubectl -n chat-with-me run -ti --rm --restart=Never --image "vectorized/redpanda:${VERSION}" -- rpk --brokers one-node-cluster-0.one-node-cluster.chat-with-me.svc.cluster.local:9092 topic consume chat-rooms
```

2. Find ip of Krakend service (krakend-service) in Kubernetes cluster
```bash
$ kubectl get svc
```

3. Send curl request
```bash
$ curl --location --request POST 'http://ENTER-YOUR-KRAKEND-SERVICE-IP-HERE:8000/redpanda' --header 'Content-Type: application/json' --data-raw '{"random": "test"}'
```

## Development commands

1. If you changed the krakend image, make newest version availabe in kind kubernetes cluster
```bash
$ kind load docker-image local-krakend:latest
```

2. Force reload of pods in kubernetes cluster
```bash
$ kubectl rollout restart deployment krakend-deployment
```

3. Read logs of krakend pod
```bash
$ kubectl logs -f $(kubectl get pod -l app=krakend -o jsonpath="{.items[0].metadata.name}")
```

4. Rebuild, update the krakend docker image in kind cluster and restart pods

```bash
$ ./reload.sh
```