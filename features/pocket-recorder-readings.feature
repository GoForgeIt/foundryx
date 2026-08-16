Feature: What a recorder said outlives the session that heard it

  A recorder answers three questions when Solleva has it on the line: how much charge is left,
  what firmware it runs, and how full it is. Today the first two are asked and thrown away when
  the session closes, the third is never asked at all, and the recorder's own page reports every
  one of them as "Unavailable" — one second after a check that read them.

  "Unavailable" is a word about Solleva dressed as a fact about the recorder. These scenarios
  replace it with two honest states: a number together with how long ago it was read, or no
  number at all beside the action that would go and ask.

  Scenario: A recorder I have not checked today shows what it knows, and how old it is
    Given a recorder whose battery and free space were read twenty minutes ago
    And whose firmware has never been asked
    When I open that recorder's page
    Then the battery and the free space each show a number and how long ago it was read
    And the firmware shows no number and offers the action that would ask
    And nothing on that page reads "Unavailable" or "N/A"

  Scenario: Checking the recorder writes down what it said
    Given a remembered recorder that reports its charge, its firmware and how full it is
    When Solleva checks that recorder
    Then what the recorder said is kept against that recorder, each fact with the moment it was read
    And how full it is is a number, and the number came off the recorder

  Scenario: A reading survives a session that could not repeat it
    Given a recorder whose battery was read an hour ago
    When Solleva checks that recorder and the recorder answers nothing
    Then the battery still shows the hour-old number, and still says it is an hour old
    And no fact was replaced by a fresher-looking guess

  Scenario: A recorder nobody has ever checked invents nothing
    Given a remembered recorder nobody has ever checked
    When I open that recorder's page
    Then every fact shows no number and offers the action that would ask
    And nothing on that page reads "Unavailable" or "N/A"
