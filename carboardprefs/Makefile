ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:16.5

THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk


BUNDLE_NAME = carboardprefs

carboardprefs_FILES = $(wildcard *.m) ../src/CRPreferences.mm
carboardprefs_INSTALL_PATH = /Library/PreferenceBundles
carboardprefs_FRAMEWORKS = UIKit
carboardprefs_PRIVATE_FRAMEWORKS = Preferences
carboardprefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	mkdir -p $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences
	cp entry.plist $(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/carboardprefs.plist
	
