.PHONY: build-video build-flight build-manager build-all push-all create-update help

REGISTRY ?= registry.airolit.com/airos
VERSION ?= $(shell cat versions.env | grep AIROS_VIDEO_VERSION | cut -d= -f2)

help:
	@echo "AirOS Container Build System"
	@echo ""
	@echo "Build targets:"
	@echo "  build-video     Build airos-video container image"
	@echo "  build-flight    Build airos-flight container image"
	@echo "  build-manager   Build airos-manager container image"
	@echo "  build-all       Build all container images"
	@echo ""
	@echo "Deploy targets:"
	@echo "  create-update   Create update .zip package"
	@echo "  push-all        Push all images to registry"
	@echo ""
	@echo "Variables:"
	@echo "  REGISTRY=$(REGISTRY)"

build-video:
	docker build -t airos-video:$(shell grep AIROS_VIDEO_VERSION versions.env | cut -d= -f2) \
		--build-arg MEDIAMTX_VERSION=$(shell grep MEDIAMTX_VERSION versions.env | cut -d= -f2) \
		containers/airos-video/

build-flight:
	docker build -t airos-flight:$(shell grep AIROS_FLIGHT_VERSION versions.env | cut -d= -f2) \
		--build-arg ACC_VERSION=$(shell grep ACC_VERSION versions.env | cut -d= -f2) \
		--build-arg NMEA_VERSION=$(shell grep NMEA_VERSION versions.env | cut -d= -f2) \
		--build-arg MAVLINK_ROUTER_VERSION=$(shell grep MAVLINK_ROUTER_VERSION versions.env | cut -d= -f2) \
		--build-arg MAVLINK_LOGGER_VERSION=$(shell grep MAVLINK_LOGGER_VERSION versions.env | cut -d= -f2) \
		--build-arg MAVLINK_SENDER_VERSION=$(shell grep MAVLINK_SENDER_VERSION versions.env | cut -d= -f2) \
		containers/airos-flight/

build-manager:
	docker build -t airos-manager:$(shell grep AIROS_MANAGER_VERSION versions.env | cut -d= -f2) \
		containers/airos-manager/

build-all: build-video build-flight build-manager

create-update:
	@echo "Creating update package..."
	$(eval AIROS_VER := $(shell grep AIROS_VIDEO_VERSION versions.env | cut -d= -f2))
	@mkdir -p out/update-$(AIROS_VER)
	@# Save container images
	docker save airos-video:$(shell grep AIROS_VIDEO_VERSION versions.env | cut -d= -f2) | gzip > out/update-$(AIROS_VER)/airos-video.tar.gz
	docker save airos-flight:$(shell grep AIROS_FLIGHT_VERSION versions.env | cut -d= -f2) | gzip > out/update-$(AIROS_VER)/airos-flight.tar.gz
	docker save airos-manager:$(shell grep AIROS_MANAGER_VERSION versions.env | cut -d= -f2) | gzip > out/update-$(AIROS_VER)/airos-manager.tar.gz
	@# Copy compose and config files
	cp docker-compose.yml out/update-$(AIROS_VER)/
	cp versions.env out/update-$(AIROS_VER)/
	@# Generate manifest with checksums
	cd out/update-$(AIROS_VER) && python3 -c "\
	import hashlib, json, os, datetime; \
	files = {}; \
	for f in os.listdir('.'): \
	    if f == 'manifest.json': continue; \
	    h = hashlib.sha256(open(f,'rb').read()).hexdigest(); \
	    t = 'image' if f.endswith('.tar.gz') else 'config'; \
	    files[f] = {'sha256': h, 'type': t}; \
	json.dump({'version': '$(AIROS_VER)', 'created': datetime.datetime.utcnow().isoformat()+'Z', 'files': files}, open('manifest.json','w'), indent=2)"
	@# Create zip
	cd out && zip -r airos-update-$(AIROS_VER).zip update-$(AIROS_VER)/
	@rm -rf out/update-$(AIROS_VER)
	@echo "Update package: out/airos-update-$(AIROS_VER).zip"

push-all:
	$(eval VID_VER := $(shell grep AIROS_VIDEO_VERSION versions.env | cut -d= -f2))
	$(eval FLT_VER := $(shell grep AIROS_FLIGHT_VERSION versions.env | cut -d= -f2))
	$(eval MGR_VER := $(shell grep AIROS_MANAGER_VERSION versions.env | cut -d= -f2))
	docker tag airos-video:$(VID_VER) $(REGISTRY)/video:$(VID_VER)
	docker tag airos-flight:$(FLT_VER) $(REGISTRY)/flight:$(FLT_VER)
	docker tag airos-manager:$(MGR_VER) $(REGISTRY)/manager:$(MGR_VER)
	docker push $(REGISTRY)/video:$(VID_VER)
	docker push $(REGISTRY)/flight:$(FLT_VER)
	docker push $(REGISTRY)/manager:$(MGR_VER)
