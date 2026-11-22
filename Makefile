KIT := NeedledropKit
REPLAY := swift run --package-path $(KIT) -c release needledrop-replay
FIXTURE := Fixtures/synthetic-side.wav

.PHONY: test project app run app-signed run-signed synth analyze play devices listen

test:            ## Unit + replay integration tests
	swift test --package-path $(KIT)

project:         ## Regenerate Needledrop.xcodeproj from project.yml
	xcodegen generate

app: project     ## Build the app (ad-hoc signed)
	xcodebuild -project Needledrop.xcodeproj -scheme Needledrop -configuration Debug \
		-derivedDataPath .build/xcode CODE_SIGN_IDENTITY=- build | grep -E "error:|BUILD"

run: app
	open .build/xcode/Build/Products/Debug/Needledrop.app

app-signed: project  ## Build signed with the team in project.yml (needed for ShazamKit)
	xcodebuild -project Needledrop.xcodeproj -scheme Needledrop -configuration Debug \
		-derivedDataPath .build/xcode -allowProvisioningUpdates build | grep -E "error:|BUILD"

run-signed: app-signed
	open .build/xcode/Build/Products/Debug/Needledrop.app

synth:           ## Write a synthetic side with known ground truth
	$(REPLAY) synth $(FIXTURE)

analyze:         ## make analyze FILE=side.wav [ARGS="--start-db -45"]
	$(REPLAY) analyze $(or $(FILE),$(FIXTURE)) $(ARGS)

play:            ## Real-time replay through the live path
	$(REPLAY) play $(or $(FILE),$(FIXTURE)) $(ARGS)

devices:
	$(REPLAY) devices

listen:          ## make listen [ARGS="--device <uid>"]
	$(REPLAY) listen $(ARGS)
