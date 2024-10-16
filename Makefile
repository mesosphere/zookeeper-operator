# Copyright (c) 2018 Dell Inc., or its subsidiaries. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0

SHELL=/bin/bash -o pipefail
# Produce CRDs that work back to Kubernetes 1.11 (no version conversion)
CRD_OPTIONS ?= "crd"

PROJECT_NAME=zookeeper-operator
EXPORTER_NAME=zookeeper-exporter
APP_NAME=zookeeper
RELEASE_REGISTRY ?= ghcr.io
REPO=mesosphere/$(PROJECT_NAME)
TEST_REPO=testzkop/$(PROJECT_NAME)
APP_REPO=mesosphere/$(APP_NAME)
VERSION=$(shell git describe --always --tags --dirty | tr -d "v" | sed "s/\(.*\)-g`git rev-parse --short HEAD`/\1/")
GIT_SHA=$(shell git rev-parse --short HEAD)
TEST_IMAGE=$(TEST_REPO)-testimages:$(VERSION)
DOCKER_TEST_PASS=testzkop@123
DOCKER_TEST_USER=testzkop
.PHONY: all build check clean test
# Get the currently used golang install path (in GOPATH/bin, unless GOBIN is set)
ifeq (,$(shell go env GOBIN))
GOBIN=$(shell go env GOPATH)/bin
else
GOBIN=$(shell go env GOBIN)
endif

# Install CRDs into a cluster
install: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl apply -f -

# Uninstall CRDs from a cluster
uninstall: manifests kustomize
	$(KUSTOMIZE) build config/crd | kubectl delete -f -

crds: ## Generate CRDs
	- make controller-gen
	- $(CONTROLLER_GEN) crd paths=./api/... output:dir=./config/crd/bases schemapatch:manifests=./config/crd/bases


# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy: manifests kustomize
	cd config/manager && $(KUSTOMIZE) edit set image ghcr.io/mesosphere/zookeeper-operator=$(TEST_IMAGE)
	$(KUSTOMIZE) build config/default | kubectl apply -f -

# Deploy controller in the configured Kubernetes cluster in ~/.kube/config
deploy-test: manifests kustomize
	cd config/test
	$(KUSTOMIZE) build config/test | kubectl apply -f -

# Undeploy controller in the configured Kubernetes cluster in ~/.kube/config
undeploy-test: manifests kustomize
	cd config/test
	$(KUSTOMIZE) build config/test | kubectl apply -f -

# Undeploy controller in the configured Kubernetes cluster in ~/.kube/config
undeploy:
	$(KUSTOMIZE) build config/default | kubectl delete -f -

# Generate manifests e.g. CRD, RBAC etc.
manifests: controller-gen
	$(CONTROLLER_GEN) $(CRD_OPTIONS) rbac:roleName=manager-role webhook paths="./..." output:crd:artifacts:config=config/crd/bases

# Run go fmt against code
fmt:
	go fmt ./...

# Run go vet against code
vet:
	go vet ./...

## Location to install dependencies to
LOCALBIN ?= $(shell pwd)/bin
$(LOCALBIN):
	mkdir -p $(LOCALBIN)
## Tool Binaries
KUSTOMIZE ?= $(LOCALBIN)/kustomize
CONTROLLER_GEN ?= $(LOCALBIN)/controller-gen
## Tool Versions
KUSTOMIZE_VERSION ?= v3.5.4
CONTROLLER_TOOLS_VERSION ?= v0.9.0
KUSTOMIZE_INSTALL_SCRIPT ?= "https://raw.githubusercontent.com/kubernetes-sigs/kustomize/master/hack/install_kustomize.sh"
.PHONY: kustomize
kustomize: $(KUSTOMIZE) ## Download kustomize locally if necessary.
$(KUSTOMIZE): $(LOCALBIN)
	test -s $(LOCALBIN)/kustomize || { curl -s $(KUSTOMIZE_INSTALL_SCRIPT) | bash -s -- $(subst v,,$(KUSTOMIZE_VERSION)) $(LOCALBIN); }
.PHONY: controller-gen
controller-gen: $(CONTROLLER_GEN) ## Download controller-gen locally if necessary.
$(CONTROLLER_GEN): $(LOCALBIN)
	test -s $(LOCALBIN)/controller-gen || GOBIN=$(LOCALBIN) go install sigs.k8s.io/controller-tools/cmd/controller-gen@$(CONTROLLER_TOOLS_VERSION)

all: generate check build

generate:
	$(CONTROLLER_GEN) object paths="./..."
	make manifests
	# sync crd generated to helm-chart
	echo '{{- if .Values.crd.create }}' > charts/zookeeper-operator/templates/zookeeper.pravega.io_zookeeperclusters_crd.yaml
	cat config/crd/bases/zookeeper.pravega.io_zookeeperclusters.yaml >> charts/zookeeper-operator/templates/zookeeper.pravega.io_zookeeperclusters_crd.yaml
	echo '{{- end }}' >> charts/zookeeper-operator/templates/zookeeper.pravega.io_zookeeperclusters_crd.yaml


build: test build-go build-image build-zk-image

build-go:
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
		-ldflags "-X github.com/$(REPO)/pkg/version.Version=$(VERSION) -X github.com/$(REPO)/pkg/version.GitSHA=$(GIT_SHA)" \
		-o bin/$(PROJECT_NAME)-linux-amd64 main.go
	CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
		-ldflags "-X github.com/$(REPO)/pkg/version.Version=$(VERSION) -X github.com/$(REPO)/pkg/version.GitSHA=$(GIT_SHA)" \
		-o bin/$(EXPORTER_NAME)-linux-amd64 cmd/exporter/main.go
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build \
		-ldflags "-X github.com/$(REPO)/pkg/version.Version=$(VERSION) -X github.com/$(REPO)/pkg/version.GitSHA=$(GIT_SHA)" \
		-o bin/$(PROJECT_NAME)-darwin-amd64 main.go
	CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build \
		-ldflags "-X github.com/$(REPO)/pkg/version.Version=$(VERSION) -X github.com/$(REPO)/pkg/version.GitSHA=$(GIT_SHA)" \
		-o bin/$(EXPORTER_NAME)-darwin-amd64 cmd/exporter/main.go
	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build \
		-ldflags "-X github.com/$(REPO)/pkg/version.Version=$(VERSION) -X github.com/$(REPO)/pkg/version.GitSHA=$(GIT_SHA)" \
		-o bin/$(PROJECT_NAME)-windows-amd64.exe main.go
	CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build \
		-ldflags "-X github.com/$(REPO)/pkg/version.Version=$(VERSION) -X github.com/$(REPO)/pkg/version.GitSHA=$(GIT_SHA)" \
		-o bin/$(EXPORTER_NAME)-windows-amd64.exe cmd/exporter/main.go

build-image:
	docker build --build-arg VERSION=$(VERSION) --build-arg DOCKER_REGISTRY=$(DOCKER_REGISTRY) --build-arg DISTROLESS_DOCKER_REGISTRY=$(DISTROLESS_DOCKER_REGISTRY) --build-arg GIT_SHA=$(GIT_SHA) -t $(RELEASE_REGISTRY)/$(REPO):$(VERSION) .
	docker tag $(RELEASE_REGISTRY)/$(REPO):$(VERSION) $(RELEASE_REGISTRY)/$(REPO):latest

build-zk-image:

	docker build --build-arg VERSION=$(VERSION)  --build-arg DOCKER_REGISTRY=$(DOCKER_REGISTRY) --build-arg GIT_SHA=$(GIT_SHA) -t $(RELEASE_REGISTRY)/$(APP_REPO):$(VERSION) ./docker
	docker tag $(RELEASE_REGISTRY)/$(APP_REPO):$(VERSION) $(RELEASE_REGISTRY)/$(APP_REPO):latest

build-zk-image-swarm:
	docker build --build-arg VERSION=$(VERSION)-swarm  --build-arg DOCKER_REGISTRY=$(DOCKER_REGISTRY) --build-arg GIT_SHA=$(GIT_SHA) \
		-f ./docker/Dockerfile-swarm -t $(RELEASE_REGISTRY)/$(APP_REPO):$(VERSION)-swarm ./docker

test:
	go test $$(go list ./... | grep -v /vendor/ | grep -v /test/e2e) -race -coverprofile=coverage.txt -covermode=atomic

test-e2e: test-e2e-remote

test-e2e-remote:
	make test-login
	docker build . -t $(TEST_IMAGE)
	docker push $(TEST_IMAGE)
	make deploy
	RUN_LOCAL=false go test -v -timeout 2h ./test/e2e... -args -ginkgo.v
	make undeploy

test-e2e-local:
	make deploy-test
	RUN_LOCAL=true go test -v -timeout 2h ./test/e2e... -args -ginkgo.v
	make undeploy-test

run-local:
	go run ./main.go

login:
	@docker login -u "$(DOCKER_USER)" -p "$(DOCKER_PASS)"

test-login:
	echo "$(DOCKER_TEST_PASS)" | docker login -u "$(DOCKER_TEST_USER)" --password-stdin

push: build-image build-zk-image
	docker push $(RELEASE_REGISTRY)/$(REPO):$(VERSION)
	docker push $(RELEASE_REGISTRY)/$(REPO):latest
	docker push $(RELEASE_REGISTRY)/$(APP_REPO):$(VERSION)
	docker push $(RELEASE_REGISTRY)/$(APP_REPO):latest

clean:
	rm -f bin/$(PROJECT_NAME)

check: check-format check-license

check-format:
	./scripts/check_format.sh

check-license:
	./scripts/check_license.sh
