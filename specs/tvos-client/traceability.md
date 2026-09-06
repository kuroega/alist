# AListTV Requirement Traceability

| Requirement | Implementation symbol | Test / scenario |
|---|---|---|
| TVOS-CONN-001 | `ServerURLValidator.validate(_:)` | `ServerURLValidatorTests`; HTTPS path-prefix manual login |
| TVOS-AUTH-001 | `AListClient.login(username:password:otpCode:)`, `AListClient.makeRequest` | `AListClientContractTests.testLoginRequestHeadersBodyAndBasePath` |
| TVOS-AUTH-002 | `ConnectionViewModel.submit()`, `ConnectionViewModel.submitOTP(_:)` | `ConnectionViewModelTests.testOTPChallengeRetriesSameCredentials`; `AListTVUITests.testOTPChallengeThenLogin` |
| TVOS-AUTH-003 | `ConnectionViewModel.commitLogin(_:)`, `KeychainCredentialStore`, `ConnectionPreferences` | `ConnectionViewModelTests.testTokenSaveFailureDoesNotConnect`; `KeychainCredentialStoreTests` |
| TVOS-AUTH-004 | `AListClient.currentUser()`, `AppContainer.restoreSession()` | `AListClientContractTests.testAuthenticatedHeaders`; `ConnectionViewModelTests.testRecoveryUnauthorizedDeletesToken`; `testRecoveryTransportFailureRetainsToken` |
| TVOS-BROWSE-001 | `BrowserViewModel.loadInitial()`, `BrowserViewModel.appendPage(_:parentPath:)`, `BrowserViewModel.updateItems()` | `BrowserViewModelTests.testRootRequestAndStableDirectoryPartition`; `AListTVUITests.testLoginThenBrowseRoot` |
| TVOS-BROWSE-002 | `AListPath.join(parent:name:)`, `BrowserViewModel.open(_:)`, `BrowserViewModel.moveToParent()` | `AListPathTests`; `BrowserViewModelTests.testReturnRestoresFocus`; manual focus-state scenario |
| TVOS-BROWSE-003 | `BrowserViewModel.loadNextPageIfNeeded(currentItem:)`, `BrowserViewModel.appendPage(_:)` | `BrowserViewModelTests.testPaginationDeduplicates`; `testLegacyHasMoreFallback`; `testConcurrentThresholdRequestsOnce`; 500+ item scenario |
| TVOS-PLAY-001 | `PlayerCoordinator.play(object:)`, `PlayableURLValidator.validate(_:)` | `PlayerCoordinatorTests.testGetPrecedesItemCreation`; `testRejectsInsecureAndEmptyRawURL`; `/p` manual playback |
| TVOS-PLAY-002 | `PlayerCoordinator.handleFailure(_:)` | `PlayerCoordinatorTests.testFirstFailureRefreshesAndRestores`; `testSecondFailureDoesNotRefresh`; expiring URL scenario |
| TVOS-PLAY-003 | `PlaybackProgressStore.update(identity:position:duration:)`, `PlayerCoordinator.resumableProgress` | `PlaybackProgressStoreTests`; resume and 90% manual scenarios |
| TVOS-PLAY-004 | `PlaybackPresentation.clampedSeekTarget(_:,duration:)`, `VLCPlayerControllerAdapter.seek(to:)` | `PlayerControllerModelTests.testSeekTargetClamping`; visible controls and Remote manual scenario |
| TVOS-PLAY-005 | `PlayerCoordinator.discoverExternalSubtitles(session:path:)`, `PlayerCoordinator.selectSubtitle(_:)`, `VLCPlayerControllerAdapter.addExternalSubtitle(url:id:title:)` | `PlayerCoordinatorTests` discovery/selection cases; `AListTVUITests.testSubtitleSelectionJourney` |
| TVOS-PLAY-006 | `VLCPlayerControllerAdapter.selectAudioTrack(id:)` | `AListTVUITests.testAudioSelectionJourney`; embedded-audio device scenario |
| TVOS-PLAY-007 | `VLCPlayerControllerAdapter.refreshDiagnostics(force:)`, `PlaybackDiagnosticsPanel` | `PlayerControllerModelTests.testDiagnosticsFormattingHandlesAbsentMetadata`; `AListTVUITests.testDiagnosticsToggleJourney` |
| TVOS-PLAY-008 | `PlaybackSettingsStore`, `PlaybackPresentation.isNearEnd(currentTime:duration:)`, `VLCPlayerControllerAdapter.handleStateChange(_:)`, `PlayerCoordinator.nextMedia(after:)`, `PlayerCoordinator.advanceToNextMedia(session:)`, `PlayerView` autoplay control | `PlayerControllerModelTests.testNearEndRequiresKnownDurationAndAllowsSmallTimingDrift`, `testPlaybackSettingsStoreDefaultsToEnabledAndPersistsChanges`; `PlayerCoordinatorTests.testEndedAutomaticallyPlaysNextMediaInFilenameOrder`, `testAutoPlayCanBeDisabled`, `testAutoPlayStopsAtDirectoryEnd`; `AListTVUITests.testAutoplayNextMediaAdvancesInTheSamePlayer`, `testAutoplayNextMediaCanBeDisabled` |
| TVOS-SEC-001 | `ServerURLValidator`, `PlayableURLValidator`, default `URLSession` trust handling | Release Info.plist inspection; self-signed and HTTP negative scenarios |
