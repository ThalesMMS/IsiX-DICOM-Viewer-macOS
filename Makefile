.PHONY: Horos clean

CONFIG ?= Debug
DERIVED_DATA ?= build

Horos:
	xcodebuild -project "Horos.xcodeproj" -scheme Horos -configuration "$(CONFIG)" -derivedDataPath "$(DERIVED_DATA)" -clonedSourcePackagesDirPath "$(DERIVED_DATA)/SourcePackages" -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile

clean:
	@rm -rf ./build
