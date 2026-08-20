Feature: Every number Solleva prints about a recorder was measured on a recorder

  One bench sitting on 2026-08-16 put a real recorder on the line for the first time. Before it,
  every figure this program carried about a Pocket descended from a third-party decode of a
  firmware nobody here has ever run.

  Evidence is only worth having if it governs what we say. So these scenarios are not about the
  bench. They are about the surfaces: each figure the recorder page can print has to name
  something a recorder actually said, and the figures nobody measured have to be absent — not
  softened, not hedged, absent.

  Scenario: Every figure the recorder page can print names something a recorder said
    Given the figures Solleva can print about a recorder
    Then each printed figure names an observation taken off a recorder
    And each of those observations is on file, naming the recorder and the firmware it ran
    And at least one figure is printed

  Scenario: A recording's row states nothing about its extent until somebody measured it
    Given a recorder that lists two recordings whose real sizes were measured later
    When I open that recorder's page
    Then no row states a size or a length drawn from the listing
    And a row whose real byte count is known does state how long it runs

  Scenario: A figure whose only support is a planning guess is refused
    Given the figures Solleva can print about a recorder
    Then every figure resting on a planning guess is withheld
    And each withheld figure says why nobody has measured it yet

  Scenario: What the recorder answered is kept word for word, and so is what it was never asked
    Given the bench sitting held on the recorder
    Then the recorder's answer about its network credentials is recorded exactly as it came back
    And the recorder's answer about deleting a file that cannot exist is recorded exactly as it came back
    And what nobody measured is written down beside it, so it cannot be quoted as a result
