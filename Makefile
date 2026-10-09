.PHONY: Horos clean

CONFIG ?= Debug
DERIVED_DATA ?= build

# Config.xcconfig leaves the development team empty, and the targets' automatic
# signing then stops the build. Without a team, given here or in the untracked
# Config.local.xcconfig, the build is signed ad hoc instead.
ifneq ($(HOROS_DEVELOPMENT_TEAM),)
SIGNING = HOROS_DEVELOPMENT_TEAM="$(HOROS_DEVELOPMENT_TEAM)"
else ifeq ($(wildcard Config.local.xcconfig),)
SIGNING = CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
endif

Horos:
	xcodebuild -project "Horos.xcodeproj" -scheme Horos -configuration "$(CONFIG)" -derivedDataPath "$(DERIVED_DATA)" -clonedSourcePackagesDirPath "$(DERIVED_DATA)/SourcePackages" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile $(SIGNING)

clean:
	@rm -rf ./build
