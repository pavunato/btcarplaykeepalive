export THEOS_PACKAGE_SCHEME = rootless
export TARGET = iphone:clang:16.5:15.0
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = BTCarPlayKeepAlive

BTCarPlayKeepAlive_FILES = BTCarPlayKeepAlive.m
BTCarPlayKeepAlive_FILES += BTKLog.m
BTCarPlayKeepAlive_CFLAGS = -fobjc-arc
BTCarPlayKeepAlive_FRAMEWORKS = Foundation UIKit
BTCarPlayKeepAlive_PRIVATE_FRAMEWORKS = Preferences
BTCarPlayKeepAlive_LDFLAGS = -Wl,-segalign,4000

include $(THEOS_MAKE_PATH)/tweak.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/DEBIAN"$(ECHO_END)
	$(ECHO_NOTHING)cp control "$(THEOS_STAGING_DIR)/DEBIAN/control"$(ECHO_END)
