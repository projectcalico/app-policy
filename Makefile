PACKAGE_NAME=github.com/projectcalico/app-policy
GO_BUILD_VER=v0.28

# app-policy still relies on vendoring
GOMOD_VENDOR=true

###############################################################################
# Download and include Makefile.common
#   Additions to EXTRA_DOCKER_ARGS need to happen before the include since
#   that variable is evaluated when we declare DOCKER_RUN and siblings.
###############################################################################
MAKE_BRANCH?=$(GO_BUILD_VER)
MAKE_REPO?=https://raw.githubusercontent.com/projectcalico/go-build/$(MAKE_BRANCH)

Makefile.common: Makefile.common.$(MAKE_BRANCH)
	cp "$<" "$@"
Makefile.common.$(MAKE_BRANCH):
	# Clean up any files downloaded from other branches so they don't accumulate.
	rm -f Makefile.common.*
	curl $(MAKE_REPO)/Makefile.common -o "$@"

# Build mounts for running in "local build" mode. This allows an easy build using local development code,
# assuming that there is a local checkout of libcalico in the same directory as this repo.
ifdef LOCAL_BUILD
PHONY: set-up-local-build
LOCAL_BUILD_DEP:=set-up-local-build

EXTRA_DOCKER_ARGS+=-v $(CURDIR)/../libcalico-go:/go/src/github.com/projectcalico/libcalico-go:rw

$(LOCAL_BUILD_DEP):
	$(DOCKER_RUN) $(CALICO_BUILD) go mod edit -replace=github.com/projectcalico/libcalico-go=../libcalico-go
endif

include Makefile.common

###############################################################################

BUILD_IMAGE?=calico/dikastes
PUSH_IMAGES?=$(BUILD_IMAGE) quay.io/calico/dikastes
RELEASE_IMAGES?=gcr.io/projectcalico-org/dikastes eu.gcr.io/projectcalico-org/dikastes asia.gcr.io/projectcalico-org/dikastes us.gcr.io/projectcalico-org/dikastes

# Build mounts for running in "local build" mode. This allows an easy build using local development code,
# assuming that there is a local checkout of libcalico in the same directory as this repo.
PHONY:$(LOCAL_BUILD_DEP)

ifdef LOCAL_BUILD
EXTRA_DOCKER_ARGS+=-v $(CURDIR)/../libcalico-go:/go/src/github.com/projectcalico/libcalico-go:rw
$(LOCAL_BUILD_DEP):
	$(DOCKER_RUN) $(CALICO_BUILD) go mod edit -replace=github.com/projectcalico/libcalico-go=../libcalico-go
else
$(LOCAL_BUILD_DEP):
	@echo "Building app-policy"
endif

DOCKER_RUN_PB := docker run --rm \
		$(EXTRA_DOCKER_ARGS) \
		--user $(LOCAL_USER_ID):$(MY_GID) \
		-v $(CURDIR):/code

ENVOY_API=vendor/github.com/envoyproxy/data-plane-api
EXT_AUTH=$(ENVOY_API)/envoy/service/auth/v2/
EXT_AUTH_V2_ALPHA=$(ENVOY_API)/envoy/service/auth/v2alpha/
ADDRESS=$(ENVOY_API)/envoy/api/v2/core/address
V2_BASE=$(ENVOY_API)/envoy/api/v2/core/base
HTTP_STATUS=$(ENVOY_API)/envoy/type/http_status
PERCENT=$(ENVOY_API)/envoy/type/percent

.PHONY: clean
## Clean enough that a new release build will be clean
clean:
	rm -rf .go-pkg-cache
	find . -name '*.created-$(ARCH)' -exec rm -f {} +
	rm -rf report vendor
	# Only one pb.go file exists outside the vendor dir
	rm -rf bin vendor proto/felixbackend.pb.go
	-docker rmi $(BUILD_IMAGE):latest-$(ARCH)
	-docker rmi $(BUILD_IMAGE):$(VERSION)-$(ARCH)
ifeq ($(ARCH),amd64)
	-docker rmi $(BUILD_IMAGE):latest
	-docker rmi $(BUILD_IMAGE):$(VERSION)
endif

###############################################################################
# Updating pins
###############################################################################
update-pins: update-libcalico-pin

###############################################################################
# Building the binary
###############################################################################
.PHONY: build-all
## Build the binaries for all architectures and platforms
build-all: $(addprefix bin/dikastes-,$(VALIDARCHES))

.PHONY: build
## Build the binary for the current architecture and platform
build: bin/dikastes-$(ARCH) bin/healthz-$(ARCH)

## Create the vendor directory
vendor: go.mod go.sum mod-download
	$(DOCKER_RUN) $(CALICO_BUILD) bash -c ' \
		mkdir -p vendor/github.com/envoyproxy/data-plane-api/envoy; \
		mkdir -p vendor/github.com/gogo/protobuf; \
		mkdir -p vendor/github.com/gogo/googleapis; \
		mkdir -p vendor/github.com/lyft/protoc-gen-validate; \
		mkdir -p vendor/github.com/golang/protobuf; \
		cp -fr `go list -m -f "{{.Dir}}" github.com/gogo/protobuf`/* vendor/github.com/gogo/protobuf; \
		cp -fr `go list -m -f "{{.Dir}}" github.com/envoyproxy/data-plane-api`/* vendor/github.com/envoyproxy/data-plane-api; \
		cp -fr `go list -m -f "{{.Dir}}" github.com/lyft/protoc-gen-validate`/* vendor/github.com/lyft/protoc-gen-validate; \
		cp -fr `go list -m -f "{{.Dir}}" github.com/golang/protobuf`/* vendor/github.com/golang/protobuf; \
		chmod -R +w vendor; \
		go mod vendor'

bin/dikastes-amd64: ARCH=amd64
bin/dikastes-arm64: ARCH=arm64
bin/dikastes-ppc64le: ARCH=ppc64le
bin/dikastes-s390x: ARCH=s390x
bin/dikastes-%: $(LOCAL_BUILD_DEP) vendor proto $(SRC_FILES)
	mkdir -p bin
	$(DOCKER_RUN_RO) \
	  -v $(CURDIR)/bin:/go/src/$(PACKAGE_NAME)/bin \
	  $(CALICO_BUILD) go build $(BUILD_FLAGS) -ldflags "-X main.VERSION=$(GIT_VERSION) -s -w" -v -o bin/dikastes-$(ARCH) ./cmd/dikastes

bin/healthz-amd64: ARCH=amd64
bin/healthz-arm64: ARCH=arm64
bin/healthz-ppc64le: ARCH=ppc64le
bin/healthz-s390x: ARCH=s390x
bin/healthz-%: $(LOCAL_BUILD_DEP) vendor proto $(SRC_FILES)
	mkdir -p bin || true
	-mkdir -p .go-pkg-cache $(GOMOD_CACHE) || true
	$(DOCKER_RUN_RO) \
	  -v $(CURDIR)/bin:/go/src/$(PACKAGE_NAME)/bin \
	  $(CALICO_BUILD) go build $(BUILD_FLAGS) -ldflags "-X main.VERSION=$(GIT_VERSION) -s -w" -v -o bin/healthz-$(ARCH) ./cmd/healthz

# We use gogofast for protobuf compilation.  Regular gogo is incompatible with
# gRPC, since gRPC uses golang/protobuf for marshalling/unmarshalling in that
# case.  See https://github.com/gogo/protobuf/issues/386 for more details.
# Note that we cannot seem to use gogofaster because of incompatibility with
# Envoy's validation library.
# When importing, we must use gogo versions of google/protobuf and
# google/rpc (aka googleapis).
PROTOC_IMPORTS =  -I $(ENVOY_API) \
		  -I vendor/github.com/gogo/protobuf/protobuf \
		  -I vendor/github.com/gogo/protobuf \
		  -I vendor/github.com/lyft/protoc-gen-validate\
		  -I vendor/github.com/gogo/googleapis\
		  -I proto\
		  -I ./
# Also remap the output modules to gogo versions of google/protobuf and google/rpc
PROTOC_MAPPINGS = Menvoy/api/v2/core/address.proto=github.com/envoyproxy/data-plane-api/envoy/api/v2/core,Menvoy/api/v2/core/base.proto=github.com/envoyproxy/data-plane-api/envoy/api/v2/core,Menvoy/type/http_status.proto=github.com/envoyproxy/data-plane-api/envoy/type,Menvoy/type/percent.proto=github.com/envoyproxy/data-plane-api/envoy/type,Mgogoproto/gogo.proto=github.com/gogo/protobuf/gogoproto,Mgoogle/protobuf/any.proto=github.com/gogo/protobuf/types,Mgoogle/protobuf/duration.proto=github.com/gogo/protobuf/types,Mgoogle/protobuf/struct.proto=github.com/gogo/protobuf/types,Mgoogle/protobuf/timestamp.proto=github.com/gogo/protobuf/types,Mgoogle/protobuf/wrappers.proto=github.com/gogo/protobuf/types,Mgoogle/rpc/status.proto=github.com/gogo/googleapis/google/rpc,Menvoy/service/auth/v2/external_auth.proto=github.com/envoyproxy/data-plane-api/envoy/service/auth/v2

proto: $(EXT_AUTH)external_auth.pb.go $(EXT_AUTH_V2_ALPHA)external_auth.pb.go $(ADDRESS).pb.go $(V2_BASE).pb.go $(HTTP_STATUS).pb.go $(PERCENT).pb.go $(EXT_AUTH)attribute_context.pb.go proto/felixbackend.pb.go proto/healthz.proto

$(EXT_AUTH)external_auth.pb.go $(EXT_AUTH)attribute_context.pb.go: $(EXT_AUTH)external_auth.proto $(EXT_AUTH)attribute_context.proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      $(EXT_AUTH)*.proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):$(ENVOY_API)

$(EXT_AUTH_V2_ALPHA)external_auth.pb.go: $(EXT_AUTH_V2_ALPHA)external_auth.proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      $(EXT_AUTH_V2_ALPHA)*.proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):$(ENVOY_API)

$(ADDRESS).pb.go $(V2_BASE).pb.go: $(ADDRESS).proto $(V2_BASE).proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      $(ADDRESS).proto $(V2_BASE).proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):$(ENVOY_API)

$(HTTP_STATUS).pb.go: $(HTTP_STATUS).proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      $(HTTP_STATUS).proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):$(ENVOY_API)

$(PERCENT).pb.go: $(PERCENT).proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      $(PERCENT).proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):$(ENVOY_API)

$(EXT_AUTH)external_auth.proto $(EXT_AUTH_V2_ALPHA)external_auth.proto $(ADDRESS).proto $(V2_BASE).proto $(HTTP_STATUS).proto $(PERCENT).proto $(EXT_AUTH)attribute_context.proto: vendor

proto/felixbackend.pb.go: proto/felixbackend.proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      proto/*.proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):proto

proto/healthz.pb.go: proto/healthz.proto
	$(DOCKER_RUN_PB) -v $(CURDIR):/src:rw \
		      $(PROTOC_CONTAINER) \
		      $(PROTOC_IMPORTS) \
		      proto/*.proto \
		      --gogofast_out=plugins=grpc,$(PROTOC_MAPPINGS):proto

###############################################################################
# Building the image
###############################################################################
CONTAINER_CREATED=.dikastes.created-$(ARCH)
.PHONY: image $(BUILD_IMAGE)
image: $(BUILD_IMAGE)
image-all: $(addprefix sub-image-,$(VALIDARCHES))
sub-image-%:
	$(MAKE) image ARCH=$*

$(BUILD_IMAGE): $(CONTAINER_CREATED)
$(CONTAINER_CREATED): Dockerfile.$(ARCH) bin/dikastes-$(ARCH) bin/healthz-$(ARCH)
	docker build -t $(BUILD_IMAGE):latest-$(ARCH) --build-arg QEMU_IMAGE=$(CALICO_BUILD) --build-arg GIT_VERSION=$(GIT_VERSION) -f Dockerfile.$(ARCH) .
ifeq ($(ARCH),amd64)
	docker tag $(BUILD_IMAGE):latest-$(ARCH) $(BUILD_IMAGE):latest
endif
	touch $@

###############################################################################
# Image build/push
###############################################################################
# we want to be able to run the same recipe on multiple targets keyed on the image name
# to do that, we would use the entire image name, e.g. calico/node:abcdefg, as the stem, or '%', in the target
# however, make does **not** allow the usage of invalid filename characters - like / and : - in a stem, and thus errors out
# to get around that, we "escape" those characters by converting all : to --- and all / to ___ , so that we can use them
# in the target, we then unescape them back
escapefs = $(subst :,---,$(subst /,___,$(1)))
unescapefs = $(subst ---,:,$(subst ___,/,$(1)))

imagetag:
ifndef IMAGETAG
	$(error IMAGETAG is undefined - run using make <target> IMAGETAG=X.Y.Z)
endif

## push one arch
push: imagetag $(addprefix sub-single-push-,$(call escapefs,$(PUSH_IMAGES)))

sub-single-push-%:
	docker push $(call unescapefs,$*:$(IMAGETAG)-$(ARCH))

## push all arches
push-all: imagetag $(addprefix sub-push-,$(VALIDARCHES))
sub-push-%:
	$(MAKE) push ARCH=$* IMAGETAG=$(IMAGETAG)

## push multi-arch manifest where supported
push-manifests: imagetag  $(addprefix sub-manifest-,$(call escapefs,$(PUSH_MANIFEST_IMAGES)))
sub-manifest-%:
	# Docker login to hub.docker.com required before running this target as we are using
	# $(DOCKER_CONFIG) holds the docker login credentials path to credentials based on
	# manifest-tool's requirements here https://github.com/estesp/manifest-tool#sample-usage
	docker run -t --entrypoint /bin/sh -v $(DOCKER_CONFIG):/root/.docker/config.json $(CALICO_BUILD) -c "/usr/bin/manifest-tool push from-args --platforms $(call join_platforms,$(VALIDARCHES)) --template $(call unescapefs,$*:$(IMAGETAG))-ARCH --target $(call unescapefs,$*:$(IMAGETAG))"

 ## push default amd64 arch where multi-arch manifest is not supported
push-non-manifests: imagetag $(addprefix sub-non-manifest-,$(call escapefs,$(PUSH_NONMANIFEST_IMAGES)))
sub-non-manifest-%:
ifeq ($(ARCH),amd64)
	docker push $(call unescapefs,$*:$(IMAGETAG))
else
	$(NOECHO) $(NOOP)
endif

## tag images of one arch for all supported registries
tag-images: imagetag $(addprefix sub-single-tag-images-arch-,$(call escapefs,$(PUSH_IMAGES))) $(addprefix sub-single-tag-images-non-manifest-,$(call escapefs,$(PUSH_NONMANIFEST_IMAGES)))

sub-single-tag-images-arch-%:
	docker tag $(BUILD_IMAGE):latest-$(ARCH) $(call unescapefs,$*:$(IMAGETAG)-$(ARCH))

# because some still do not support multi-arch manifest
sub-single-tag-images-non-manifest-%:
ifeq ($(ARCH),amd64)
	docker tag $(BUILD_IMAGE):latest-$(ARCH) $(call unescapefs,$*:$(IMAGETAG))
else
	$(NOECHO) $(NOOP)
endif

## tag images of all archs
tag-images-all: imagetag $(addprefix sub-tag-images-,$(VALIDARCHES))
sub-tag-images-%:
	$(MAKE) tag-images ARCH=$* IMAGETAG=$(IMAGETAG)

###############################################################################
# UT/FVs
###############################################################################
.PHONY: ut
ut: $(LOCAL_BUILD_DEP) proto
	mkdir -p report
	$(DOCKER_RUN) $(CALICO_BUILD) /bin/bash -c "go test -v $(BUILD_FLAGS) ./... | go-junit-report > ./report/tests.xml"

fv st:
	@echo "No FVs or STs currently available"

###############################################################################
# CI
###############################################################################
.PHONY: ci
ci: clean mod-download build-all static-checks ut

###############################################################################
# CD
###############################################################################
.PHONY: cd
## Deploys images to registry
cd: image-all
ifndef CONFIRM
	$(error CONFIRM is undefined - run using make <target> CONFIRM=true)
endif
ifndef BRANCH_NAME
	$(error BRANCH_NAME is undefined - run using make <target> BRANCH_NAME=var or set an environment variable)
endif
	$(MAKE) tag-images-all push-all push-manifests push-non-manifests IMAGETAG=${BRANCH_NAME} EXCLUDEARCH="$(EXCLUDEARCH)"
	$(MAKE) tag-images-all push-all push-manifests push-non-manifests IMAGETAG=$(shell git describe --tags --dirty --always --long) EXCLUDEARCH="$(EXCLUDEARCH)"

###############################################################################
# Release
###############################################################################
PREVIOUS_RELEASE=$(shell git describe --tags --abbrev=0)

## Tags and builds a release from start to finish.
release: release-prereqs
	$(MAKE) VERSION=$(VERSION) release-tag
	$(MAKE) VERSION=$(VERSION) release-build
	$(MAKE) VERSION=$(VERSION) release-verify
	@echo ""
	@echo "Release build complete. Next, push the produced images."
	@echo ""
	@echo "  make VERSION=$(VERSION) release-publish"
	@echo ""

## Produces a git tag for the release.
release-tag: release-prereqs release-notes
	git tag $(VERSION) -F release-notes-$(VERSION)
	@echo ""
	@echo "Now you can build the release:"
	@echo ""
	@echo "  make VERSION=$(VERSION) release-build"
	@echo ""

## Produces a clean build of release artifacts at the specified version.
release-build: release-prereqs clean
# Check that the correct code is checked out.
ifneq ($(VERSION), $(GIT_VERSION))
	$(error Attempt to build $(VERSION) from $(GIT_VERSION))
endif
	$(MAKE) image-all
	$(MAKE) tag-images-all IMAGETAG=$(VERSION)
	# Generate the `latest` images.
	$(MAKE) tag-images-all IMAGETAG=latest

## Verifies the release artifacts produces by `make release-build` are correct.
release-verify: release-prereqs
	# Check the reported version is correct for each release artifact.
	if ! docker run $(BUILD_IMAGE):$(VERSION)-$(ARCH) /dikastes --version | grep '^$(VERSION)$$'; then \
	  echo "Reported version:" `docker run $(BUILD_IMAGE):$(VERSION)-$(ARCH) /dikastes --version` "\nExpected version: $(VERSION)"; \
	  false; \
	else \
	  echo "Version check passed\n"; \
	fi

## Generates release notes based on commits in this version.
release-notes: release-prereqs
	mkdir -p dist
	echo "# Changelog" > release-notes-$(VERSION)
	sh -c "git cherry -v $(PREVIOUS_RELEASE) | cut '-d ' -f 2- | sed 's/^/- /' >> release-notes-$(VERSION)"

## Pushes a github release and release artifacts produced by `make release-build`.
release-publish: release-prereqs
	# Push the git tag.
	git push origin $(VERSION)

	# Push images.
	$(MAKE) push-all push-manifests push-non-manifests IMAGETAG=$(VERSION)

	@echo "Finalize the GitHub release based on the pushed tag."
	@echo ""
	@echo "  https://$(PACKAGE_NAME)/releases/tag/$(VERSION)"
	@echo ""
	@echo "If this is the latest stable release, then run the following to push 'latest' images."
	@echo ""
	@echo "  make VERSION=$(VERSION) release-publish-latest"
	@echo ""

# WARNING: Only run this target if this release is the latest stable release. Do NOT
# run this target for alpha / beta / release candidate builds, or patches to earlier Calico versions.
## Pushes `latest` release images. WARNING: Only run this for latest stable releases.
release-publish-latest: release-prereqs
	$(MAKE) push-all push-manifests push-non-manifests IMAGETAG=latest

# release-prereqs checks that the environment is configured properly to create a release.
release-prereqs:
ifndef VERSION
	$(error VERSION is undefined - run using make release VERSION=vX.Y.Z)
endif
ifdef LOCAL_BUILD
	$(error LOCAL_BUILD must not be set for a release)
endif
