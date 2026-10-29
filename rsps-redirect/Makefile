export ARCHS = arm64 arm64e
export TARGET = iphone:clang:16.5:15.0
export THEOS_PACKAGE_SCHEME = rootless

INSTALL_TARGET_PROCESSES = osclient

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = RSPSRedirect
RSPSRedirect_FILES = Tweak.x
RSPSRedirect_CFLAGS = -fobjc-arc
RSPSRedirect_FRAMEWORKS = Foundation

include $(THEOS_MAKE_PATH)/tweak.mk
