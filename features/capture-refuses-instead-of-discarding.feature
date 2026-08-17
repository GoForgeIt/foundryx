Feature: A recording that cannot be saved refuses instead of discarding the audio

  Some recordings are not authorized to write to this phone — the account that owns the
  audio has not been claimed yet, which is exactly the state a locked phone comes back in
  when Bluetooth relaunches the app in the background. Until now the recording opened
  anyway, showed itself as recording, accepted every frame, and dropped each segment's
  audio on the floor the moment it could not write it. Nobody was told. Audio a person
  spoke is not something the app may discard quietly: it must be kept, and the recording
  must say plainly that it is not saved.

  Scenario: audio is kept, not dropped, when the recording cannot be saved
    Given a recording that is not authorized to save to this phone
    When I speak enough to fill a segment
    Then nothing is written to the phone
    And none of the audio I spoke is discarded
    And the recording says it cannot be saved

  Scenario: the same speech is saved normally when the recording is authorized
    Given a recording that is authorized to save to this phone
    When I speak enough to fill a segment
    Then the audio I spoke is on the phone
    And the recording does not say it cannot be saved
