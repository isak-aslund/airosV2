.PHONY: build-video build-flight build-manager build-all \
       push-all create-update setup-buildx help

REGISTRY ?= registry.airolit.com/airos
PLATFORM ?= linux/arm64

# Parse versions from env file
VID_VER  = $(shell grep AIROS_VIDEO_VERSION versions.env | cut -d= -f2)
FLT_VER  = $(shell grep AIROS_FLIGHT_VERSION versions.env | cut -d= -f2)
MGR_VER  = $(shell grep AIROS_MANAGER_VERSION versions.env | cut -d= -f2)

help:
	@echo "AirOS Container Build System"
	@echo ""
	@echo "Setup:"
	@echo "  setup-buildx    Create buildx builder with arm64 QEMU support"
	@echo ""
	@echo "Build (cross-compile for arm64):"
	@echo "  build-video     Build airos-video image"
	@echo "  build-flight    Build airos-flight image"
	@echo "  build-manager   Build airos-manager image"
	@echo "  build-all       Build all images"
	@echo ""
	@echo "Deploy:"
	@echo "  create-update   Package images into update .zip"
	@echo "  push-all        Tag and push images to registry"
	@echo ""
	@echo "Variables:"
	@echo "  REGISTRY=$(REGISTRY)"
	@echo "  PLATFORM=$(PLATFORM)"
	@echo ""
	@echo "Images are saved to out/ as .tar files (loadable on Jetson with docker load)."

# --------------------------------------------------------------------------
# Buildx setup — run once to enable arm64 cross-compilation on x86_64
# --------------------------------------------------------------------------
setup-buildx:
	@echo "Registering QEMU for arm64 emulation..."
	docker run --privileged --rm tonistiigi/binfmt --install arm64
	@echo "Creating buildx builder..."
	-docker buildx create --name airos-builder --driver docker-container \
		--platform linux/amd64,linux/arm64
	docker buildx use airos-builder
	docker buildx inspect --bootstrap
	@echo ""
	@echo "Ready. Run 'make build-all' to cross-compile for arm64."

# --------------------------------------------------------------------------
# Build targets
#
# Cross-compiling arm64 on x86_64: images are written to out/*.tar
# because --load cannot import foreign-arch images into the local daemon.
#
# On native arm64 (Jetson): set PLATFORM=linux/arm64 and images go straight
# into the local daemon via --load.
# --------------------------------------------------------------------------

BUILDX_CMD = docker buildx build --platform $(PLATFORM) --builder airos-builder --ssh default

build-video: out
	$(BUILDX_CMD) \
		--tag airos-video:$(VID_VER) \
		--build-arg MEDIAMTX_VERSION=$(shell grep MEDIAMTX_VERSION versions.env | cut -d= -f2) \
		--output type=docker,dest=out/airos-video.tar \
		containers/airos-video/
	@echo "Built: out/airos-video.tar ($(VID_VER))"

build-flight: out
	$(BUILDX_CMD) \
		--tag airos-flight:$(FLT_VER) \
		--build-arg ACC_VERSION=$(shell grep ACC_VERSION versions.env | cut -d= -f2) \
		--build-arg NMEA_VERSION=$(shell grep NMEA_VERSION versions.env | cut -d= -f2) \
		--build-arg MAVLINK_ROUTER_VERSION=$(shell grep MAVLINK_ROUTER_VERSION versions.env | cut -d= -f2) \
		--build-arg MAVLINK_LOGGER_VERSION=$(shell grep MAVLINK_LOGGER_VERSION versions.env | cut -d= -f2) \
		--build-arg MAVLINK_SENDER_VERSION=$(shell grep MAVLINK_SENDER_VERSION versions.env | cut -d= -f2) \
		--output type=docker,dest=out/airos-flight.tar \
		containers/airos-flight/
	@echo "Built: out/airos-flight.tar ($(FLT_VER))"

build-manager: out
	$(BUILDX_CMD) \
		--tag airos-manager:$(MGR_VER) \
		--output type=docker,dest=out/airos-manager.tar \
		containers/airos-manager/
	@echo "Built: out/airos-manager.tar ($(MGR_VER))"

build-all: build-video build-flight build-manager
	@echo ""
	@echo "All images built in out/:"
	@ls -lh out/*.tar

out:
	@mkdir -p out

# --------------------------------------------------------------------------
# Update package
# --------------------------------------------------------------------------
create-update: out
	@echo "Creating update package v$(VID_VER)..."
	@mkdir -p out/update-$(VID_VER)
	@# Compress image tars
	gzip -c out/airos-video.tar > out/update-$(VID_VER)/airos-video.tar.gz
	gzip -c out/airos-flight.tar > out/update-$(VID_VER)/airos-flight.tar.gz
	gzip -c out/airos-manager.tar > out/update-$(VID_VER)/airos-manager.tar.gz
	@# Copy config files
	cp docker-compose.yml out/update-$(VID_VER)/
	cp versions.env out/update-$(VID_VER)/
	@# Generate manifest with SHA256 checksums
	python3 scripts/generate-manifest.py out/update-$(VID_VER) $(VID_VER)
	@# Create zip
	cd out && zip -r airos-update-$(VID_VER).zip update-$(VID_VER)/
	@rm -rf out/update-$(VID_VER)
	@echo "Done: out/airos-update-$(VID_VER).zip"

# --------------------------------------------------------------------------
# Push to registry
# --------------------------------------------------------------------------
push-all:
	docker tag airos-video:$(VID_VER) $(REGISTRY)/video:$(VID_VER)
	docker tag airos-flight:$(FLT_VER) $(REGISTRY)/flight:$(FLT_VER)
	docker tag airos-manager:$(MGR_VER) $(REGISTRY)/manager:$(MGR_VER)
	docker push $(REGISTRY)/video:$(VID_VER)
	docker push $(REGISTRY)/flight:$(FLT_VER)
	docker push $(REGISTRY)/manager:$(MGR_VER)
