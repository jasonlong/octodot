set shell := ["zsh", "-cu"]

default:
  @just --list

dev:
  ./scripts/dev.sh

build:
  xcodebuild build -project Octodot.xcodeproj -scheme Octodot -configuration Debug -derivedDataPath .deriveddata

test:
  xcodebuild test -project Octodot.xcodeproj -scheme Octodot -destination 'platform=macOS' -derivedDataPath .deriveddata

watch:
  ./scripts/dev.sh --watch

restart:
  ./scripts/dev.sh --build
