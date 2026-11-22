CI failed once in the gesture storm, `DictationControllerRaceTests.testRandomGestureStormsAlwaysLeaveTheMicrophoneOff`, seed 45. The session stayed listening, the microphone stayed on, and the next dictation inserted nothing. It passed on the rerun.

I don't think it's the test. Find out whether the controller can really end up like that, and fix it if it can. Whatever I press while a paste is finishing should do what it would have done a moment later.
