TARGET := iphone:clang:latest:13.0
ARCHS = arm64 arm64e
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = TTPanel
TTPanel_FILES = Tweak.x
TTPanel_CFLAGS = -fobjc-arc
include $(THEOS_MAKE_PATH)/tweak.mk
